# frozen_string_literal: true

module Yeptris
  # The gem's version lives in the parent namespace's file — the last
  # internal require (yeptris/version) retired with it.
  VERSION = "0.1.9.1".freeze
  # The error hierarchy lives in THIS file (the parent namespace's
  # own file): nested constants do not trigger a parent-constant
  # autoload, and the law forbids internal requires — defining the
  # hierarchy here makes it eager by construction.

  # The base error for everything this library raises deliberately.
  class Error < StandardError; end

  # The input is not valid YAML (or valid for the requested mode).
  # message carries the C parser's line/column detail.
  class ParseError < Error; end

  # A handle was used after its document was freed. Raised, never a
  # segfault: the Document is the sole C-memory owner and every Node
  # checks liveness through it.
  class FreedError < Error; end

  # Building a document from a Ruby object graph hit something the
  # builder refuses (cycles, unsupported objects).
  class DumpError < Error; end

  # Input coercion — the ONE place the input boundary is typed
  # (no respond_to? duck-probing): IO-like objects read, Strings
  # pass through, anything else must be stringable and is.
  def self.read_input(source)
    case source
    when String then source
    when IO, StringIO then source.read
    else source.to_s
    end
  end

  autoload :Document, "yeptris/document"
  autoload :Node, "yeptris/node"
  autoload :YAML, "yeptris/yaml"
  autoload :Materializer, "yeptris/materializer"
  autoload :ValueML, "yeptris/valueml"
  autoload :Psych, "yeptris/psych"
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
