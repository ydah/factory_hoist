# frozen_string_literal: true

require_relative "active_record_copying"

module FactoryHoist
  module ValueCopying
    module_function

    def call(object)
      Marshal.load(Marshal.dump(object))
    end

    # Pays Marshal.dump once so that each replay only costs Marshal.load.
    def snapshot(values)
      return Snapshot::EMPTY if values.empty?

      plan = ActiveRecordCopying.plan(values)
      if plan
        begin
          plan.call
          return plan
        rescue StandardError
          # Fall through to the generic snapshot.
        end
      end

      begin
        payload = Marshal.dump(values)
        Marshal.load(payload)
        Snapshot.new(payload)
      rescue StandardError
        subset = copyable(values)
        return Snapshot::EMPTY if subset.size >= values.size

        snapshot(subset)
      end
    end

    def copyable(values)
      values.select do |_name, value|
        Marshal.load(Marshal.dump(value))
        true
      rescue StandardError
        false
      end
    end

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
