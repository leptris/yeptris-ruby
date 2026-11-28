# frozen_string_literal: true

module Yeptris
  # The gem's version lives in the parent namespace's file — the last
  # internal require (yeptris/version) retired with it.
  VERSION = "0.6.92.0".freeze

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

  # The per-minor native materializer's feature name (the org
  # native-layer contract, leptris-ruby#671 clause 2): DOT-FREE
  # yeptris/native_<major>_<minor> — MRI derives the init symbol from
  # the feature basename cut at the first dot (native_3_4.so resolves
  # Init_native_3_4). The naming SSOT is NativeLayout (the packaging
  # script and CI gates consume the same mapping).
  def self.native_bundle_feature
    NativeLayout.bundle_feature
  end

  autoload :Document, "yeptris/document"
  autoload :Node, "yeptris/node"
  autoload :YAML, "yeptris/yaml"
  autoload :JSON, "yeptris/json"
  autoload :Materializer, "yeptris/materializer"
  autoload :ValueML, "yeptris/valueml"
  autoload :Psych, "yeptris/psych"
  autoload :Schema, "yeptris/schema"
  autoload :Validation, "yeptris/validation"
  autoload :CBOR, "yeptris/cbor"
  autoload :Plan, "yeptris/plan"
  autoload :Events, "yeptris/events"
  autoload :NativeLayout, "yeptris/native_layout"
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
#
# The org native-layer contract (leptris-ruby#671 clause 2): ONE
# compiled bundle per Ruby minor, DOT-FREE, flat at
# lib/yeptris/native_<major>_<minor>.so (.bundle on darwin, one DLL
# per minor on windows — a PE DLL must bind its build Ruby's runtime,
# the #207/#227 lesson). MRI derives the init symbol from the feature
# basename cut at the first dot: native_3_4.so resolves Init_native_3_4
# (the old native-<minor>.so name asked for the untypeable
# "Init_native-3" — #157).
#
# NO unversioned fallback, ever: a bundle built by any other minor is
# a wrong-ABI load (the compiled-in RString layout changed in 3.2 —
# the 3.1 segfault class; Ruby 3.0 ran a 3.3-built ext and the JSON
# parse failed). An absent variant raises, and this top-level require
# falls back to the FFI ladder with a warning (opt-in display per the
# #217 informational-notices law — consumers assert clean stderr).
begin
  require Yeptris.native_bundle_feature
rescue LoadError => e
  if Yeptris.debug? # the require chain is top-level (self = main)
    warn "yeptris: no precompiled native materializer for Ruby " \
         "#{RUBY_VERSION[/\A\d+\.\d+/]} on this platform " \
         "(#{e.message}); the FFI ladder carries the load"
  end
end
