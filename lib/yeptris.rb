# frozen_string_literal: true

module Yeptris
  # The gem's version lives in the parent namespace's file — the last
  # internal require (yeptris/version) retired with it.
  VERSION = "0.6.21.1".freeze

  # Informational notices are OPT-IN (yeptris-ruby#217): consumers
  # embed yeptris inside CLIs that assert clean stderr, and a
  # successful fallback is not a warning. YEPTRIS_DEBUG=1 turns the
  # notices on.
  def self.debug?
    return @debug unless @debug.nil?
    v = ENV["YEPTRIS_DEBUG"]
    @debug = !v.nil? && !v.empty? && v != "0"
  end
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
  autoload :JSON, "yeptris/json"
  autoload :Materializer, "yeptris/materializer"
  autoload :ValueML, "yeptris/valueml"
  autoload :Psych, "yeptris/psych"
  autoload :Schema, "yeptris/schema"
  autoload :CBOR, "yeptris/cbor"
end

# NOTE (the #318 poisoned-process class): the Psych error-name aliases
# live BELOW the ffi require — reading Psych here would trigger the
# psych autoload BEFORE the native library resolves, and a mid-load
# ffi failure under a drop-in rebind left ::Psych rebound against a
# half-initialized FFI module (every to_yaml in the process died).
# With this order an ffi failure is a clean, loud require failure.

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


# The safe_load error names, aliased at the top level so consumers
# writing rescues need no nesting knowledge (issue #73's naming
# note): Yeptris::DisallowedClass is Yeptris::Psych::DisallowedClass.
# LAZY (const_missing): a standalone require "yeptris/psych" loads
# yeptris.rb MID-psych — an eager alias here would re-enter the
# half-loaded psych.rb through the autoload and NameError. At first
# touch psych is complete in every load order.
module Yeptris
  def self.const_missing(name)
    case name
    when :DisallowedClass, :AliasesError
      const_set(name, Psych.const_get(name))
    else
      super
    end
  end
end

# Optional C-API materializer (TODO.restructure/22): fused visit →
# Ruby objects via the Ruby C API. Feature-detected — LoadError leaves
# the FFI ladder (Marshal → columns → records) as the sole path.
# One bundle per Ruby minor (the leptris-ruby #207/#227 lesson: a PE
# DLL must bind its build Ruby's runtime; a unix bundle is also
# minor-locked by the internal API it compiles against). The MINOR
# lives in the DIRECTORY (lib/yeptris/<minor>/native.<ext>) and the
# FILE name stays unversioned: ruby derives the init symbol from the
# feature basename, so native-3.4.so asked for the untypeable
# "Init_native-3" and the versioned-file scheme could never load
# (#157 — every shipped bundle was dead code). Dev checkouts keep
# the plain native.<ext> name (mkmf layout, built for the running
# Ruby). A missing cell falls back LOUDLY to the ladder.
begin
  # per-minor FIRST: a single version-agnostic native.so loads under
  # ANY Ruby and is an ABI gamble across minors — Ruby 3.0 ran a
  # 3.3-built ext and the JSON parse failed.
  require "yeptris/#{RUBY_VERSION[/\A\d+\.\d+/]}/native"
rescue LoadError
  begin
    require "yeptris/native"
  rescue LoadError => e
    if Yeptris.debug? # the require chain is top-level (self = main)
      warn "yeptris: no precompiled native materializer for Ruby " \
           "#{RUBY_VERSION[/\A\d+\.\d+/]} on this platform " \
           "(#{e.message}); the FFI ladder carries the load"
    end
  end
end
