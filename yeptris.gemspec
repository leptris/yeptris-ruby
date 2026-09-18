# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
# The gemspec is evaluated by bundle BEFORE dependencies install, so
# it must not require the library (the ffi chain would explode). The
# version has ONE source — the parent namespace's file — read as text.
version = File.read(File.expand_path("lib/yeptris.rb", __dir__))
  .match(/\sVERSION\s=\s"([^"]+)"/)&.captures&.first
raise "VERSION not found in lib/yeptris.rb" unless version

Gem::Specification.new do |spec|
  spec.name = "yeptris"
  spec.version = version
  spec.authors = ["Ribose Inc."]
  spec.email = ["open.source@ribose.com"]

  spec.summary = "The YAML counterpart of libleptris: ultra-performance YAML 1.2 for Ruby"
  spec.description =
    "A Ruby YAML library over libyeptris — Psych-compatible semantics " \
    "with libleptris-class performance, and a fused native JSON " \
    "materializer that outperforms JSON.parse on JSON-shaped input."

  spec.homepage = "https://github.com/leptris/yeptris"
  spec.license = "MIT"

  # libyeptris rides EVERY artifact: platform gems vendor the prebuilt
  # shared lib at the gem root, and the pure `ruby`-platform gem
  # carries the C sources under vendor/ + an extension that builds
  # them at install time (no-op when a prebuilt lib is present).
  spec.files = Dir["lib/**/*.rb"] + Dir["lib/**/*.{so,dylib,dll,bundle}"] +
               Dir["*.{so,dylib}"] + Dir["ext/**/*.{c,h,rb}"] +
               Dir["vendor/libyeptris/**/*"].select { |f| File.file?(f) } +
               %w[README.adoc]
  # ONLY the pure gem builds at install: platform gems vendor the
  # prebuilt lib and must install on toolchain-free images (alpine
  # smoke containers have no make). The platform-gem script stages
  # .yeptris-platform-gem as the marker.
  spec.extensions =
    File.exist?(File.expand_path(".yeptris-platform-gem", __dir__)) ? [] : ["ext/libyeptris/extconf.rb"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.0"

  spec.add_runtime_dependency "ffi", "~> 1.15"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/releases",
  }
end
