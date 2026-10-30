# yeptris-ruby#336: the leptris bridge vendors this same native ext, so
# both gems can co-initialize in one process. The second Init_native
# re-ran rb_define_const(AVAILABLE) and warned "already initialized
# constant" — which moxml treated as an adapter load failure and fell
# back to nokogiri. The init is idempotent now; this spec loads a
# SECOND COPY of the built ext (a renamed file is a fresh dlopen, the
# same situation as the leptris bridge's vendored .so) and requires
# the load to be warning-free.
require "fileutils"
require "rbconfig"
require "tmpdir"

RSpec.describe "native co-initialization" do
  it "loads a second copy of the ext without re-defining AVAILABLE" do
    ext = $LOADED_FEATURES.grep(%r{yeptris/(?:3\.\d+/)?native\.(?:so|bundle|dll)$}).first
    skip "no prebuilt native ext loaded in this environment" unless ext

    Dir.mktmpdir do |dir|
      copy = File.join(dir, "native.#{RbConfig::CONFIG['DLEXT']}")
      FileUtils.cp(ext, copy)
      script = <<~RUBY
        require "yeptris"
        require "native"
        abort "MISSING" unless Yeptris::Native::AVAILABLE
        puts "COINIT-OK"
      RUBY
      lib = File.expand_path("../lib", __dir__)
      out = IO.popen([RbConfig.ruby, "-I", lib, "-I", dir, "-e", script],
                     err: [:child, :out], &:read)
      expect(out).to include("COINIT-OK")
      expect(out).not_to include("already initialized constant")
    end
  end
end
