# frozen_string_literal: true

# yeptris-ruby#289: the neutral surface's `when Date` referenced Date
# without loading stdlib's date, so a clean `require "yeptris"` raised
# NameError before the intended DumpError. Psych requires date itself.
# Subprocess-isolated: the suite's own load state defines Date and would
# hide the bug.
require "open3"
require "rbconfig"

RSpec.describe "Date constant (yeptris-ruby#289)" do
  let(:gem_lib) { File.expand_path("../lib", __dir__) }
  # the same resolution order spec_helper uses (spec_helper itself is
  # suite state; the subprocess must reproduce just the lib path)
  let(:lib_path) do
    ENV["YEPTRIS_LIB_PATH"] ||
      Dir[File.expand_path("../lib/platform/*/libyeptris.*", __dir__)].first ||
      begin
        sibling = File.expand_path("../../yeptris/build-validate/src/libyeptris.dylib", __dir__)
        File.exist?(sibling) ? sibling : nil
      end
  end

  def run_probe(body)
    probe = <<~RUBY
      ENV["YEPTRIS_LIB_PATH"] = #{lib_path.inspect} if #{!lib_path.nil?}
      $LOAD_PATH.unshift #{gem_lib.inspect}
      #{body}
    RUBY
    Open3.capture3(RbConfig.ruby, "-e", probe)
  end

  it "raises DumpError (not NameError) from a clean process" do
    out, err, status = run_probe(<<~RUBY)
      require "yeptris"
      begin
        Yeptris::YAML.dump(Object.new)
      rescue Yeptris::DumpError
        puts "dump_error"
      rescue NameError => e
        abort "NameError: \#{e.message}"
      end
    RUBY
    expect(status).to be_success, err
    expect(out).to include("dump_error")
  end

  it "defines Date and dumps it after require \"yeptris\" alone" do
    out, err, status = run_probe(<<~RUBY)
      require "yeptris"
      Yeptris::YAML # load the neutral surface (autoloaded)
      abort "Date not loaded" unless defined?(Date)
      puts Yeptris::YAML.dump(Date.new(2026, 10, 20))
    RUBY
    expect(status).to be_success, err
    expect(out).to include("2026-10-20")
  end
end
