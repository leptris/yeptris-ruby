# frozen_string_literal: true

# #167: Psych::VERSION must exist under the rebind — third-party
# gates (mechanize 2.14.1's cookie-jar) read it at require time.
RSpec.describe "Yeptris::Psych::VERSION (#167)" do
  it "is defined once the drop-in ran with stdlib psych preloaded" do
    require "psych"
    require "yeptris/psych/drop_in"
    expect(Psych::VERSION).to be_a(String)
    expect(Psych::VERSION).to match(/\A\d+\.\d+\.\d+/)
    # the face reports the STDLIB version it replaced
    expect(Psych::VERSION).to eq(Psych::ORIGINAL::VERSION)
  end

  it "falls back to the default-gem spec when psych was not preloaded" do
    # a fresh interpreter without stdlib psych: the drop-in resolves
    # the version from the bundled default gem's spec (no network)
    out = <<~RUBY
      require "yeptris/psych/drop_in"
      puts Psych::VERSION
    RUBY
    require "open3"
    lib = File.expand_path("../lib", __dir__)
    env = { "YEPTRIS_LIB_PATH" => ENV["YEPTRIS_LIB_PATH"] }.compact
    ver, status = Open3.capture2(env, RbConfig.ruby, "-I", lib, "-e", out)
    expect(status.success?).to be(true)
    expect(ver.strip).to match(/\A\d+\.\d+\.\d+/)
  end
end
