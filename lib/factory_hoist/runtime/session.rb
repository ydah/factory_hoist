# frozen_string_literal: true

module FactoryHoist
  module Runtime
    class Session
      def initialize
        @scopes = []
        @transaction = Transaction.new
        @examples_since_begin = 0
      end

      def enter(group, definitions, materialize: true)
        if @scopes.empty?
          @transaction.begin_outer
          @examples_since_begin = 0
        end
        scope = Scope.new(group, definitions, @scopes)
        @transaction.create_savepoint(scope.savepoint)
        @scopes << scope
        invalidate_snapshot!
        scope.materialize! if materialize
        @transaction.clear_written! if materialize && @transaction.owned?
      rescue Exception # rubocop:disable Lint/RescueException
        @scopes.pop if @scopes.last == scope
        @transaction.rollback_savepoint(scope.savepoint) if scope
        @transaction.rollback_outer if @scopes.empty?
        raise
      end

      def materialize(group)
        scope = @scopes.last
        raise Error, "hoist scope mismatch" unless scope&.group&.equal?(group)

        preserve_unmanaged_writes
        @transaction.create_savepoint(scope.savepoint)
        invalidate_snapshot!
        scope.materialize!
      rescue Exception # rubocop:disable Lint/RescueException
        @transaction.rollback_savepoint(scope.savepoint) if scope
        scope&.values&.clear
        invalidate_snapshot!
        raise
      ensure
        @transaction.clear_written! if @transaction.owned?
      end

      def leave(group)
        scope = @scopes.last
        return unless scope
        raise Error, "hoist scope mismatch" unless scope.group.equal?(group)

        @scopes.pop
        invalidate_snapshot!
        @transaction.rollback_savepoint(scope.savepoint)
        @transaction.clear_written! if @transaction.owned?
        if @scopes.empty?
          @transaction.rollback_outer
          @examples_since_begin = 0
        end
      end

      def around_example(example, local: false)
        local_transaction = @scopes.empty? && local
        return example.run if @scopes.empty? && !local

        @transaction.begin_outer if local_transaction

        preserve_unmanaged_writes
        rebuild_if_needed
        savepoint = "factory_hoist_example_#{example.object_id}"
        @transaction.create_savepoint(savepoint)
        @examples_since_begin += 1
        before = DatabaseStateDigest.call(@scopes) if FactoryHoist.configuration.paranoid_mode
        example.run
        after = DatabaseStateDigest.call(@scopes) if before
        if before && before != after
          raise SharedDataMutationError, "paranoid_mode detected changes to hoisted database rows"
        end
      ensure
        @transaction.rollback_savepoint(savepoint) if savepoint
        @transaction.clear_written! if @transaction.owned?
        if local_transaction
          @transaction.rollback_outer
          @examples_since_begin = 0
        end
      end

      def fetch(example_instance, name, fallback, definitions)
        FactoryHoist.stats.increment(:references)
        state = example_instance.instance_variable_get(:@__factory_hoist_values)
        unless state
          state = ExampleValueStore.new(example_instance, shared_snapshot, definitions)
          example_instance.instance_variable_set(:@__factory_hoist_values, state)
        end
        state.fetch(name, fallback)
      end

      def close
        @transaction.rollback_savepoints
      ensure
        @transaction.rollback_outer
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
        return unless @transaction.owned? && @transaction.written?

        # ponytail: nested hook ownership is ambiguous; defer rebuilding all active scopes unless this becomes costly.
        @scopes.each { |scope| scope.rebuildable = false }
        @transaction.clear_written!
      end

      def rebuild_if_needed
        budget = FactoryHoist.configuration.subxid_budget
        return unless @transaction.owned? && @scopes.all?(&:rebuildable) && budget.positive? && @examples_since_begin >= budget

        @transaction.rollback_outer
        @transaction.begin_outer
        invalidate_snapshot!
        @scopes.each do |scope|
          @transaction.create_savepoint(scope.savepoint)
          scope.materialize!
        end
        @transaction.clear_written!
        @examples_since_begin = 0
        FactoryHoist.stats.increment(:transaction_rebuilds)
      rescue Exception # rubocop:disable Lint/RescueException
        @transaction.rollback_outer
        @scopes.each { |scope| scope.values.clear }
        invalidate_snapshot!
        raise
      end
    end
  end
end
