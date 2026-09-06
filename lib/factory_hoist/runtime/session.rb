# frozen_string_literal: true

module FactoryHoist
  module Runtime
    class Session
      def initialize
        @scopes = []
        @transaction = Transaction.new
        @examples_since_begin = 0
      end

      def enter_scope(group, definitions, materialize: true)
        if @scopes.empty?
          @transaction.begin_outer_transaction
          @examples_since_begin = 0
        end
        scope = Scope.new(group, definitions, @scopes)
        @transaction.create_savepoint(scope.savepoint_name)
        @scopes << scope
        invalidate_snapshot!
        scope.materialize! if materialize
        @transaction.reset_write_tracking! if materialize && @transaction.owns_transaction?
      rescue Exception # rubocop:disable Lint/RescueException
        @scopes.pop if @scopes.last == scope
        @transaction.rollback_savepoint(scope.savepoint_name) if scope
        @transaction.rollback_outer_transaction if @scopes.empty?
        raise
      end

      def materialize_scope(group)
        scope = @scopes.last
        raise Error, "hoist scope mismatch" unless scope&.group&.equal?(group)

        preserve_unmanaged_writes
        @transaction.create_savepoint(scope.savepoint_name)
        invalidate_snapshot!
        scope.materialize!
      rescue Exception # rubocop:disable Lint/RescueException
        @transaction.rollback_savepoint(scope.savepoint_name) if scope
        scope&.values&.clear
        invalidate_snapshot!
        raise
      ensure
        @transaction.reset_write_tracking! if @transaction.owns_transaction?
      end

      def leave_scope(group)
        scope = @scopes.last
        return unless scope
        raise Error, "hoist scope mismatch" unless scope.group.equal?(group)

        @scopes.pop
        invalidate_snapshot!
        @transaction.rollback_savepoint(scope.savepoint_name)
        @transaction.reset_write_tracking! if @transaction.owns_transaction?
        if @scopes.empty?
          @transaction.rollback_outer_transaction
          @examples_since_begin = 0
        end
      end

      def around_example(example, local: false)
        local_transaction = @scopes.empty? && local
        return example.run if @scopes.empty? && !local

        @transaction.begin_outer_transaction if local_transaction

        preserve_unmanaged_writes
        rebuild_if_needed
        savepoint = "factory_hoist_example_#{example.object_id}"
        @transaction.create_savepoint(savepoint)
        @examples_since_begin += 1
        before = DatabaseStateDigest.call(@scopes) if FactoryHoist.configuration.paranoid_mode?
        example.run
        after = DatabaseStateDigest.call(@scopes) if before
        if before && before != after
          raise SharedDataMutationError, "paranoid_mode detected changes to hoisted database rows"
        end
      ensure
        @transaction.rollback_savepoint(savepoint) if savepoint
        @transaction.reset_write_tracking! if @transaction.owns_transaction?
        if local_transaction
          @transaction.rollback_outer_transaction
          @examples_since_begin = 0
        end
      end

      def fetch_value(example_instance, name, fallback, definitions)
        FactoryHoist.stats.increment(:references)
        state = example_instance.instance_variable_get(:@__factory_hoist_values)
        unless state
          state = ExampleValueStore.new(example_instance, shared_snapshot, definitions)
          example_instance.instance_variable_set(:@__factory_hoist_values, state)
        end
        state.fetch(name, fallback)
      end

      def close
        @transaction.rollback_all_savepoints
      ensure
        @transaction.rollback_outer_transaction
        @scopes.clear
        invalidate_snapshot!
        @examples_since_begin = 0
      end

      private

      def shared_snapshot
        @shared_snapshot ||= ValueCopying.snapshot(
          @scopes.each_with_object({}) { |scope, values| values.merge!(scope.values) }
        )
      end

      def invalidate_snapshot!
        @shared_snapshot = nil
      end

      def preserve_unmanaged_writes
        return unless @transaction.owns_transaction? && @transaction.write_detected?

        # ponytail: nested hook ownership is ambiguous; defer rebuilding all active scopes unless this becomes costly.
        @scopes.each { |scope| scope.rebuildable = false }
        @transaction.reset_write_tracking!
      end

      def rebuild_if_needed
        budget = FactoryHoist.configuration.subxid_budget
        return unless @transaction.owns_transaction? && @scopes.all?(&:rebuildable?) && budget.positive? && @examples_since_begin >= budget

        @transaction.rollback_outer_transaction
        @transaction.begin_outer_transaction
        invalidate_snapshot!
        @scopes.each do |scope|
          @transaction.create_savepoint(scope.savepoint_name)
          scope.materialize!
        end
        @transaction.reset_write_tracking!
        @examples_since_begin = 0
        FactoryHoist.stats.increment(:transaction_rebuilds)
      rescue Exception # rubocop:disable Lint/RescueException
        @transaction.rollback_outer_transaction
        @scopes.each { |scope| scope.values.clear }
        invalidate_snapshot!
        raise
      end
    end
  end
end
