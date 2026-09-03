# frozen_string_literal: true

require "yeptris/version"

module Yeptris
  # eager: nested constants (Yeptris::ParseError etc.) do NOT trigger
  # a parent-constant autoload, so the error hierarchy loads up front
  require_relative "yeptris/error"
  autoload :Document, "yeptris/document"
  autoload :Node, "yeptris/node"
  autoload :YAML, "yeptris/yaml"
  autoload :Materializer, "yeptris/materializer"
  autoload :ValueML, "yeptris/valueml"
end

# Eager native-library resolution (leptris-ruby lesson): fail at
# require time, not at first parse. The ffi require MUST come after
# the autoload registrations — ffi.rb opens module Yeptris, and
# requiring it first would shadow the manifest (leptris-ruby#53).
begin
  require "yeptris/ffi"
rescue LoadError => e
  raise LoadError, <<~MSG
    Yeptris could not load the native libyeptris library.
    Set YEPTRIS_LIB_PATH to a libyeptris.{so,dylib,dll}, or use the
    platform gem that vendors it.
    (Underlying error: #{e.message})
  MSG
end
