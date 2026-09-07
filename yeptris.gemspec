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

  # The FFI core is pure Ruby — installs never compile. The optional
  # native materializer (TODO.restructure/22) ships as SOURCE in ext/
  # for opt-in builds (see README: "Native materializer"); the gem
  # loads it only when a compiled native.so/.bundle is present and
  # silently falls back to the FFI Marshal ladder otherwise.
  spec.files = Dir["lib/**/*.rb"] + Dir["ext/**/*.{c,h,rb}"] + %w[README.adoc]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.1"

  spec.add_runtime_dependency "ffi", "~> 1.15"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/releases",
  }
end
