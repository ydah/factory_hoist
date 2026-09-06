# frozen_string_literal: true

module FactoryHoist
  module Runtime
    class Transaction
      def initialize
        @connection = nil
        @owned = false
        @savepoints = []
        @written = false
        @write_subscriber = nil
      end

      def begin_outer_transaction
        @connection = active_record_connection
        return unless @connection

        @owned = !@connection.transaction_open?
        if @owned
          @connection.begin_transaction(joinable: false)
          @write_subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
            @written = true if payload[:connection].equal?(@connection) && @connection.write_query?(payload[:sql])
          end
        end
      end

      def create_savepoint(name)
        return if @savepoints.include?(name)

        begin_outer_transaction unless connection_usable?
        return unless connection_usable?

        @connection.create_savepoint(name)
        @savepoints << name
      end

      def rollback_savepoint(name)
        return unless connection_usable? && @savepoints.include?(name)

        @connection.rollback_to_savepoint(name)
        @connection.release_savepoint(name)
        @savepoints.delete(name)
      end

      def rollback_all_savepoints
        rollback_savepoint(@savepoints.last) while connection_usable? && @savepoints.any?
      end

      def rollback_outer_transaction
        @connection.rollback_transaction if connection_usable? && @owned
      ensure
        ActiveSupport::Notifications.unsubscribe(@write_subscriber) if @write_subscriber
        @write_subscriber = nil
        @written = false
        @savepoints.clear
        @owned = false
      end

      def owns_transaction?
        @owned
      end

      def write_detected?
        @written
      end

      def reset_write_tracking!
        @written = false
      end

      private

      def connection_usable?
        @connection && @connection.transaction_open?
      rescue StandardError
        false
      end

      def active_record_connection
        return unless defined?(::ActiveRecord::Base)
        pool = ::ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          ::ActiveRecord::Base.connection_specification_name
        )
        return unless pool

        ::ActiveRecord::Base.connection
      end
    end
  end
end
