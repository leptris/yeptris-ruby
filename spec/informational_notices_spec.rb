# frozen_string_literal: true

# yeptris-ruby#217: the informational notices (the native-materializer
# miss, the psych namespace-only migration signal) are strictly
# informational — consumers embed yeptris inside CLIs that assert
# clean subprocess stderr. They are opt-in via YEPTRIS_DEBUG=1 and
# silent by construction otherwise. Subprocess-isolated: the probe
# runs in a fresh ruby so the suite's own load state can never
# contaminate the stderr assertion.
require "open3"
require "rbconfig"

RSpec.describe "informational notices (yeptris-ruby#217)" do
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
  let(:probe) do
    <<~RUBY
      ENV["YEPTRIS_LIB_PATH"] = #{lib_path.inspect} if #{!lib_path.nil?}
      $LOAD_PATH.unshift #{gem_lib.inspect}
      module ::Psych; end      # stdlib psych present: the namespace
                               # notice's precondition
      require "yeptris"
      require "yeptris/psych"
      puts Yeptris::VERSION
    RUBY
  end

  it "loads with clean stderr by default" do
    out, err, status = Open3.capture3(
      RbConfig.ruby, "-e", probe
    )
    expect(status).to be_success
    expect(out).to include(Yeptris::VERSION)
    expect(err).to be_empty
  end

  it "prints the notices under YEPTRIS_DEBUG=1" do
    out, err, status = Open3.capture3(
      { "YEPTRIS_DEBUG" => "1" }, RbConfig.ruby, "-e", probe
    )
    expect(status).to be_success
    expect(out).to include(Yeptris::VERSION)
    expect(err).to include("defines the namespace only")
  end
end
