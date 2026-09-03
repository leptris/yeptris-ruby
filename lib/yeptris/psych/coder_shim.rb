# frozen_string_literal: true

module Yeptris
  module Psych
    # Minimal Psych::Coder stand-in (encode_with / init_with carry
    # these): tag + one of scalar / seq / map. map is ordered.
    class CoderShim
      attr_reader :type, :tag, :scalar, :seq

      def initialize(class_name = nil)
        @type = :map
        # Psych's default for encode_with objects: their own class tag
        @tag = class_name ? "!ruby/object:#{class_name}" : nil
        @scalar = nil
        @seq = nil
        @map = nil
        @class_name = class_name
      end

      def tag=(t)
        @tag = t
      end

      def scalar=(value)
        @type = :scalar
        @scalar = value
      end

      def seq=(list)
        @type = :seq
        @seq = list
      end

      def map=(hash)
        @type = :map
        @map = nil
        hash&.each { |k, v| self[k] = v }
      end

      def []=(key, value)
        @type = :map
        @map ||= {}
        @map[key.to_s] = value
      end

      def [](key)
        @map&.[](key.to_s)
      end

      def each(&block)
        @map&.each(&block)
      end
    end
  end
end
