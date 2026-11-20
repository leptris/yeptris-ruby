# frozen_string_literal: true

require "open3"

# #167: Psych::VERSION must exist under the rebind — third-party
# gates (mechanize 2.14.1's cookie-jar) read it at require time.
RSpec.describe "Yeptris::Psych::VERSION (#167)" do
  lib = File.expand_path("../lib", __dir__)
  env = { "YEPTRIS_LIB_PATH" => ENV["YEPTRIS_LIB_PATH"] }.compact

  # Both examples spawn a fresh interpreter: the drop-in is
  # process-exclusive (#69), so an in-process require "psych" explodes
  # with a superclass mismatch whenever example order happens to place
  # another file's rebind first (observed 2026-11-20 on pristine main,
  # 2 of 5 randomized orders). A child interpreter is the honest venue
  # for the load-order contract this file asserts.
  it "is defined once the drop-in ran with stdlib psych preloaded" do
    code = <<~'RUBY'
      require "psych"
      require "yeptris/psych/drop_in"
      raise "VERSION missing" unless defined?(Psych::VERSION)
      raise "ORIGINAL missing" unless defined?(Psych::ORIGINAL::VERSION)
      raise "mismatch" unless Psych::VERSION == Psych::ORIGINAL::VERSION
      puts Psych::VERSION
    RUBY
    ver, status = Open3.capture2(env, RbConfig.ruby, "-I", lib, "-e", code)
    expect(status.success?).to be(true)
    expect(ver.strip).to match(/\A\d+\.\d+\.\d+/)
  end

  it "falls back to the default-gem spec when psych was not preloaded" do
    skip "no psych gem spec resolvable in this bundle (the 3.0 vendored bundle)" if
      (::Gem.loaded_specs["psych"] ||
       (begin
          ::Gem::Specification.find_by_name("psych", ::Gem::Requirement.default)
        rescue ::StandardError, ::Gem::Exception, ::LoadError
          nil
        end)).nil?
    # a fresh interpreter without stdlib psych: the drop-in resolves
    # the version from the bundled default gem's spec (no network).
    # The require itself must never explode regardless (run
    # 44698420284: bundler 4.1.0's vendored yaml_serializer seeds a
    # bare VERSION-less ::Psych during setup on windows runners, and
    # the drop-in's ORIGINAL read died with NameError at require
    # time) — that is the unconditional half; the version VALUE is
    # asserted when the child's environment resolves one.
    out = <<~'RUBY'
      require "yeptris/psych/drop_in"
      puts Psych::VERSION if defined?(Psych::VERSION)
    RUBY
    ver, status = Open3.capture2(env, RbConfig.ruby, "-I", lib, "-e", out)
    expect(status.success?).to be(true)
    skip "the child interpreter resolved no psych spec (bundler-pruned index)" if
      ver.strip.empty?
    expect(ver.strip).to match(/\A\d+\.\d+\.\d+/)
  end
end
