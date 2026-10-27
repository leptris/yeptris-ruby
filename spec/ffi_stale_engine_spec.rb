# frozen_string_literal: true

# The oiml-cs report's class: a stale libyeptris on the machine (the
# Windows base-name dedupe makes a system copy win) must fail with
# the FRIENDLY load error — not a mid-file attach abort that leaves
# the module half-defined ('uninitialized constant NODE_SCALAR' at
# the next autoload).
RSpec.describe "stale engine library handling" do
  SOMEForeignLib = [
    "/usr/lib/libz.dylib", "/usr/lib/libz.1.2.12.dylib",
    "/usr/lib/libSystem.B.dylib", "/usr/lib/libobjc-trampolines.dylib",
    "C:/Windows/System32/kernel32.dll",
  ].find { |p| File.exist?(p) }

  def load_with(lib)
    lib_path = File.expand_path("../lib", __dir__)
    out, st = Open3.capture2e(
      { "YEPTRIS_LIB_PATH" => lib, "BUNDLE_GEMFILE" => ENV["BUNDLE_GEMFILE"] },
      RbConfig.ruby, "-I", lib_path, "-e", "require 'yeptris'"
    )
    [out, st]
  end

  it "raises the friendly error for a library without our symbols" do
    skip "no foreign system library to simulate with" unless SOMEForeignLib
    out, st = load_with(SOMEForeignLib)
    expect(st.success?).to be(false)
    expect(out).to include("older than this gem").or include("cannot load the libyeptris")
  end

  it "keeps every constant defined when the load fails" do
    # the failure must surface INSIDE ffi.rb — the constants (and the
    # autoload targets) are either all there or never reached
    skip "no foreign system library to simulate with" unless SOMEForeignLib
    out, = load_with(SOMEForeignLib)
    expect(out).not_to include("uninitialized constant")
  end
end

require "open3"
require "rbconfig"
