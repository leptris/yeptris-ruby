# frozen_string_literal: true

# #169: the packaging-doctrine gate — every gem carries the engine
# build inputs; platform gems carry the prebuilt binary beside them.
# These specs exercise the gate itself against synthetic gems (the
# real assemblies run it in build-platform-gem.sh).
require "tmpdir"
require "fileutils"
require "rubygems/package"

RSpec.describe "scripts/audit_gem_doctrine.rb (#169)" do
  let(:script) { File.expand_path("../scripts/audit_gem_doctrine.rb", __dir__) }

  def build_gem(platform:, with_source: true, with_binary: false, with_ext: true)
    dir = Dir.mktmpdir
    files = []
    if with_source
      files << "vendor/libyeptris/CMakeLists.txt"
      files << "ext/libyeptris/extconf.rb"
      60.times { |i| files << "vendor/libyeptris/src/f#{i}.c" }
    end
    files << "ext/libyeptris/extconf.rb" if with_ext && !with_source
    files << "lib/yeptris/native-3.4.so" if with_binary
    files << "lib/libyeptris.dylib" if with_binary && platform.to_s.include?("darwin")
    files.each do |f|
      path = File.join(dir, f)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "x")
    end
    # a clean subprocess: under this suite another spec may have
    # rebound ::Psych, and gem build's internal to_yaml must not
    # route through the rebind (real assemblies never run under it)
    builder = File.join(dir, "build_gem.rb")
    File.write(builder, <<~RUBY)
      require "rubygems/package"
      spec = Gem::Specification.new do |s|
        s.name = "yeptris-test"
        s.version = "0.0.0"
        s.platform = #{platform.inspect}
        s.author = "t"
        s.summary = "doctrine test gem"
        s.files = #{files.inspect}
      end
      print Gem::Package.build(spec)
    RUBY
    out = IO.popen([RbConfig.ruby, builder], chdir: dir, err: "/dev/null", &:read)
    name = out[/File:\s*(\S+\.gem)/, 1]
    abort "gem build produced no gem: #{out.inspect}" if name.nil?
    File.join(dir, name)
  end

  def run_audit(gem)
    require "open3"
    out, st = Open3.capture2e(RbConfig.ruby, script, gem)
    warn "audit output: #{out.inspect}" unless st.success?
    st.success?
  end

  after { FileUtils.remove_entry(Dir.mktmpdir) if false } # tmpdirs GC'd; gems are self-contained

  it "accepts a platform gem with binary + engine source" do
    expect(run_audit(build_gem(platform: "x86_64-linux", with_binary: true))).to be_truthy
  end

  it "accepts the pure ruby gem (source + build-on-install ext)" do
    expect(run_audit(build_gem(platform: "ruby"))).to be_truthy
  end

  it "rejects a platform gem without the prebuilt binary" do
    expect(run_audit(build_gem(platform: "x86_64-linux", with_binary: false))).to be_falsey
  end

  it "rejects any gem without the engine build inputs" do
    expect(run_audit(build_gem(platform: "ruby", with_source: false, with_ext: false))).to be_falsey
    expect(run_audit(build_gem(platform: "x86_64-linux", with_source: false, with_binary: true))).to be_falsey
  end
end
