# frozen_string_literal: true

# Standalone-repo defaults, in order: explicit override, a vendored
# platform copy, or the sibling C checkout's build (in-tree
# development before the platform gems exist)
lib = ENV["YEPTRIS_LIB_PATH"] ||
      Dir[File.expand_path("../lib/platform/*/libyeptris.*", __dir__)].first
if lib.nil?
  sibling = File.expand_path("../../yeptris/build-validate/src/libyeptris.dylib", __dir__)
  lib = sibling if File.exist?(sibling)
end
ENV["YEPTRIS_LIB_PATH"] = lib unless lib.nil?

require "yeptris"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.disable_monkey_patching!
  config.order = :random
end
