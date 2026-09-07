# frozen_string_literal: true

# TODO.restructure/23 — the typed opt-in marker for arbitrary-object
# dump/load. Classes include this module and implement
# encode_with(coder) / init_with(coder) (Psych's coder protocol).
# The visitors call those methods directly; the library never uses
# respond_to?, never reads or writes instance variables from outside
# the object's public surface (the encapsulation law).
module Yeptris
  module Psych
    module Encodable
    end
  end
end
