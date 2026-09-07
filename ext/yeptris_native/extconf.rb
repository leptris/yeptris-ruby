# frozen_string_literal: true

require "mkmf"

# libyeptris location: YEPTRIS_LIB_PATH (file or dir), then sibling
# checkouts. CI sets YEPTRIS_LIB_PATH (the built shared library) and
# YEPTRIS_SRC (the C checkout) explicitly.
lib_path = ENV["YEPTRIS_LIB_PATH"]
candidates = []
if lib_path
  candidates << File.dirname(lib_path)
  candidates << lib_path if File.directory?(lib_path)
end
candidates << File.expand_path("../../../../yeptris/build-validate/src", __dir__)
candidates << File.expand_path("../../../../yeptris/build/src", __dir__)
candidates << File.expand_path("../../../yeptris/build-validate/src", __dir__)
candidates << File.expand_path("../../../yeptris/build/src", __dir__)

# Source root: YEPTRIS_SRC (CI / explicit), then sibling checkouts.
src_roots = [ENV["YEPTRIS_SRC"]].compact
src_roots << File.expand_path("../../../../yeptris/src", __dir__)
src_roots << File.expand_path("../../../yeptris/src", __dir__)
src_root = src_roots.find { |d| d && File.directory?(File.join(d, "include")) }
abort "yeptris sources not found (set YEPTRIS_SRC)" unless src_root

$INCFLAGS << " -I#{src_root}/include -I#{src_root}/yeptris"
%w[build-validate/generated build/generated].each do |g|
  d = File.join(File.dirname(src_root), g)
  $INCFLAGS << " -I#{d}" if File.directory?(d)
end

libdir = candidates.find do |d|
  d && File.directory?(d) && Dir[File.join(d, "libyeptris*.{dylib,so,dll}")].any?
end
abort "libyeptris not found (set YEPTRIS_LIB_PATH)" unless libdir

$LIBPATH << libdir
$LDFLAGS << " -Wl,-rpath,#{libdir}" if RUBY_PLATFORM =~ /linux|darwin/
have_library("yeptris", "yep_json_string") or abort "yep_json_string not exported — rebuild libyeptris"
have_library("yeptris", "yeptris_visit_json") or abort "yeptris_visit_json missing"

$CFLAGS << " -O3 -fvisibility=hidden" unless RUBY_PLATFORM =~ /mswin|mingw/
create_makefile("yeptris/native")
