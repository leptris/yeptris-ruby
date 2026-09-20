# frozen_string_literal: true

# Packaging-doctrine audit gate (#169): compiled packages carry the
# engine binary AND its source; source packages compile it on install.
# Unpacks a built .gem and asserts both halves — a failure fails the
# assembly (gates beat conventions; leptris-py's 1.9.208.0 lesson and
# leptris-py#158's publish gate are the pattern).
#
#   ruby scripts/audit_gem_doctrine.rb <path/to/yeptris-*.gem>

require "rubygems/package"

def fail_gate(gem, msg)
  abort "doctrine FAIL #{File.basename(gem)}: #{msg}"
end

def audit(gem_path)
  spec = Gem::Package.new(gem_path).spec
  files = spec.files.map { |f| f.start_with?("/") ? f[1..] : f }
  name = File.basename(gem_path)

  # EVERY gem carries the engine build inputs (the recompile half)
  %w[vendor/libyeptris/CMakeLists.txt ext/libyeptris/extconf.rb].each do |must|
    fail_gate(name, "missing #{must}") unless files.include?(must)
  end
  src = files.count { |f| f.start_with?("vendor/libyeptris/src/") }
  fail_gate(name, "only #{src} vendored engine source files") if src < 50

  if spec.platform.to_s == "ruby"
    puts "pure ruby gem OK (source + build-on-install ext): #{name}"
    return
  end

  # Platform gems: the prebuilt engine rides beside the sources
  binary = files.any? { |f| f =~ /\.(so|dylib|dll|bundle)\z/i }
  fail_gate(name, "platform gem without the prebuilt engine binary") unless binary
  puts "platform gem OK (binary + engine source): #{name} [#{spec.platform}]"
end

ARGV.each { |g| audit(g) }
abort "no gems given (usage: audit_gem_doctrine.rb <yeptris-*.gem>...)" if ARGV.empty?
puts "gem doctrine OK: #{ARGV.length} gem(s)"
