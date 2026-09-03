# frozen_string_literal: true

module FactoryHoist
  module ValueCopying
    class Snapshot
      def initialize(payload)
        @payload = payload
      end

      def call
        Marshal.load(@payload)
      end

      EMPTY = new(nil)
      def EMPTY.call = {}
    end
  end
end
