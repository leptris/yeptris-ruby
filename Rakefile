# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

def platform_tag
  @platform_tag ||= case RUBY_PLATFORM
                    when /arm64-darwin/ then "arm64-darwin"
                    when /x86_64-darwin/ then "x86_64-darwin"
                    when /aarch64-linux-musl/ then "aarch64-linux-musl"
                    when /aarch64-linux/ then "aarch64-linux"
                    when /x86_64-linux-musl/ then "x86_64-linux-musl"
                    when /x86_64-linux/ then "x86_64-linux"
                    else RUBY_PLATFORM
                    end
end

namespace :vendor do
  desc "Copy the locally built libyeptris into lib/ for this platform"
  task :local do
    lib = ENV["YEPTRIS_LIB_PATH"]
    raise "set YEPTRIS_LIB_PATH to the built library" unless lib

    ext = File.extname(lib)
    dest = File.join("lib", "platform", platform_tag, "libyeptris#{ext}")
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(lib, dest)
    puts "vendored #{lib} -> #{dest}"
  end
end

namespace :audit do
  desc "Verify every ffi.rb attach has an exported symbol in the built library"
  task :symbols do
    lib = Dir["lib/platform/*/libyeptris.*", ENV["YEPTRIS_LIB_PATH"]].compact.first
    raise "no library found (rake vendor:local or set YEPTRIS_LIB_PATH)" unless lib

    require "set"
    # T = defined here; U = an import the library links against
    # (libc's free, for the owned-pointer release) — both satisfy
    # an attach
    # nm lines: [addr] type symbol — the type is always second
    # from the END (2-field import lines have no address)
    nm = `nm -g #{lib.shellescape}`.lines.map(&:split)
    exported = nm.filter_map do |f|
      next unless f.length >= 2

      sym = f[-1]
      sym = sym.sub(/\A_/, "") if sym.start_with?("_")
      sym if %w[T U].include?(f[-2])
    end.to_set
    attached = File.read("lib/yeptris/ffi.rb")
                  .scan(/attach_function :(\w+)(?:, :(\w+))?/)
                  .map { |name, real| real || name }
    missing = attached.reject { |a| exported.include?(a) }
    missing.each { |m| puts "MISSING SYMBOL: #{m}" }
    puts "audit: #{attached.size - missing.size}/#{attached.size} symbols present"
    abort "symbol audit failed" unless missing.empty?
  end
end

task default: :spec
