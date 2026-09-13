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
