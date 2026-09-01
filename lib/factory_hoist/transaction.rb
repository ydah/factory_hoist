# frozen_string_literal: true

module FactoryHoist
  module Runtime
    class Transaction
      def initialize
        @connection = nil
        @owned = false
        @savepoints = []
      end

      def begin_outer
        @connection = active_record_connection
        return unless @connection

        @owned = !@connection.transaction_open?
        @connection.begin_transaction(joinable: false) if @owned
      end

      def create_savepoint(name)
        return unless usable?

        @connection.create_savepoint(name)
        @savepoints << name
      end

      def rollback_savepoint(name)
        return unless usable? && @savepoints.include?(name)

        @connection.rollback_to_savepoint(name)
        @connection.release_savepoint(name)
        @savepoints.delete(name)
      end

      def rollback_outer
        @connection.rollback_transaction if usable? && @owned
      ensure
        @savepoints.clear
        @owned = false
      end

      def owned?
        @owned
      end

      private

      def usable?
        @connection && @connection.transaction_open?
      end

      def active_record_connection
        return unless defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.connected?

        ::ActiveRecord::Base.connection
      rescue StandardError
        nil
      end
    end
  end
end
