# frozen_string_literal: true

# The process-exclusive drop-in (issue #69): rebinds the top-level
# Psych constant to Yeptris::Psych. Once this runs, stdlib psych must
# NOT be loaded afterwards — its require would re-open THIS module and
# clobber constants ("already initialized" warnings, then
# NameError/NoMethodError at call time). Bundles that cannot
# guarantee the load order (activesupport et al.) should require
# "yeptris/psych" only and reference Yeptris::Psych directly.
require "yeptris" # the autoload declarations (Document, Node, ...) live here
require "yeptris/psych"

# ( Psych-stdlib, if already loaded, stays reachable as
# ::Psych::ORIGINAL.)
if defined?(::Psych) && !::Psych.equal?(Yeptris::Psych) &&
   !Yeptris::Psych.const_defined?(:ORIGINAL, false)
  Yeptris::Psych.const_set(:ORIGINAL, ::Psych)
end
# class_eval reaches Module-private methods WITHOUT send (the law: no
# send to private methods); remove_const has no public form, and the
# rebind is this file's whole purpose
Object.class_eval { remove_const(:Psych) } if defined?(::Psych) && !::Psych.equal?(Yeptris::Psych)
::Psych = Yeptris::Psych

# #167: third-party gems feature-gate on Psych::VERSION at require
# time (mechanize 2.14.1's cookie-jar reads it in a class body). The
# face reports the STDLIB version it replaces: ORIGINAL's when psych
# was preloaded, else the default-gem spec's version (local lookup —
# requiring stdlib psych post-rebind is censored by the header).
unless Yeptris::Psych.const_defined?(:VERSION, false)
  version =
    if Yeptris::Psych.const_defined?(:ORIGINAL, false)
      Yeptris::Psych::ORIGINAL::VERSION
    else
      spec = begin
        ::Gem.loaded_specs["psych"] ||
          ::Gem::Specification.find_by_name("psych", ::Gem::Requirement.default)
      rescue ::StandardError
        nil
      end
      spec&.version&.to_s
    end
  Yeptris::Psych.const_set(:VERSION, version) if version
end

# yaml-first boot order: ::YAML still references the ORIGINAL stdlib
# module object, whose singleton methods route through stdlib's parse
# stream — the UTF-8 tagging (and every other normalization) never
# runs (#135's spec/sdo discriminant). Delegate the original's public
# singleton surface to the Yeptris face so BOTH constants behave
# identically regardless of which module object a caller holds.
# ORIGINAL exists only when stdlib psych was already loaded (the
# drop-in-before-psych order needs no delegation — nothing references
# the original yet).
if ::Yeptris::Psych.const_defined?(:ORIGINAL, false)
  ::Psych::ORIGINAL.singleton_class.class_eval do
    ::Psych::ORIGINAL.singleton_methods(false).each do |m|
      define_method(m) do |*args, **kwargs, &block|
        ::Yeptris::Psych.public_send(m, *args, **kwargs, &block)
      end
    end
  end
end
