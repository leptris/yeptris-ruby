# frozen_string_literal: true

require "mkmf"

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

src_root = [
  File.expand_path("../../../../yeptris/src", __dir__),
  File.expand_path("../../../yeptris/src", __dir__),
].find { |d| d && File.directory?(File.join(d, "include")) }
abort "yeptris sources not found" unless src_root

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
