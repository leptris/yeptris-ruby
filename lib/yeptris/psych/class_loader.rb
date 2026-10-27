# frozen_string_literal: true

require "date"

module Yeptris
  module Psych
    # The minimal ClassLoader face the ScalarScanner port drives
    # (stdlib's loader resolves through the class hierarchy; the
    # scanner only needs the date class and symbolize).
    class ClassLoader
      def date
        Date
      end

      def symbolize str
        str.to_sym
      end

      def load name
        Object.const_get(name)
      end
    end
  end
end
