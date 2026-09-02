# frozen_string_literal: true

require "openssl"
require_relative "database_snapshot"
require_relative "deep_copy"
require_relative "definition"
require_relative "transaction"

module FactoryHoist
  module Runtime
    THREAD_KEY = :factory_hoist_runtime

    module_function

    def current
      Thread.current[THREAD_KEY] ||= Session.new
    end

    def reset!
      Thread.current[THREAD_KEY]&.close
    ensure
      Thread.current[THREAD_KEY] = nil
    end

    def seed(node_path, key, index = 0)
      input = [FactoryHoist.configuration.suite_seed, node_path, key, index].join("\0")
      OpenSSL::Digest.digest("BLAKE2b512", input).unpack1("Q>")
    end

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
        before = DatabaseSnapshot.call(@scopes) if FactoryHoist.configuration.paranoid_mode
        example.run
        after = DatabaseSnapshot.call(@scopes) if before
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
          state = ExampleValues.new(example_instance, shared_snapshot, definitions)
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
        @shared_snapshot ||= DeepCopy.snapshot(
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

    class Scope
      attr_accessor :rebuildable
      attr_reader :definitions, :group, :values

      def initialize(group, definitions, ancestors)
        @group = group
        @definitions = definitions
        @ancestors = ancestors.dup
        @values = {}
        @materializing = []
        @rebuildable = true
      end

      def savepoint
        @savepoint ||= "factory_hoist_group_#{group.object_id}"
      end

      def materialize!
        @values = {}
        context = MaterializationContext.new(@ancestors, self)
        @definitions.each_key { |name| materialize_one(name, context) }
      end

      def materialize_one(name, context)
        return @values.fetch(name) if @values.key?(name)
        raise Error, "circular hoist dependency: #{(@materializing + [name]).join(' -> ')}" if @materializing.include?(name)

        definition = @definitions.fetch(name)
        @materializing << name
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @values[name] = definition.materialize(context)
        FactoryHoist.stats.increment(:materializations)
        FactoryHoist.stats.record_cost(
          "#{definition.node_path} #{name}",
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        )
        @values.fetch(name)
      ensure
        @materializing.pop if @materializing.last == name
      end
    end

    class MaterializationContext
      def initialize(ancestors, current)
        @scopes = ancestors + [current]
      end

      def [](name)
        __factory_hoist_fetch__(name)
      end

      def __factory_hoist_evaluate__(&block)
        instance_exec(&block)
      end

      def method_missing(name, ...)
        return __factory_hoist_fetch__(name) if __factory_hoist_available?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        __factory_hoist_available?(name) || super
      end

      private

      def __factory_hoist_available?(name)
        @scopes.reverse_each.any? { |scope| scope.values.key?(name) || scope.definitions.key?(name) }
      end

      def __factory_hoist_fetch__(name)
        scope = @scopes.reverse_each.find { |candidate| candidate.values.key?(name) }
        if scope
          definition = scope.definitions.fetch(name)
          FactoryHoist.stats.record_reference("#{definition.node_path} #{name}")
          return scope.values.fetch(name)
        end

        scope = @scopes.reverse_each.find { |candidate| candidate.definitions.key?(name) }
        if scope
          definition = scope.definitions.fetch(name)
          FactoryHoist.stats.record_reference("#{definition.node_path} #{name}")
          return scope.materialize_one(name, self)
        end

        raise KeyError, "unknown hoist: #{name}"
      end
    end

    class ExampleValues
      def initialize(example, snapshot, definitions)
        @example = example
        @definitions = definitions
        @values = snapshot.call
        @local = {}
        @materializing = []
      end

      def fetch(name, fallback = nil)
        definition = @definitions[name] || fallback
        FactoryHoist.stats.record_reference("#{definition.node_path} #{name}") if definition
        return @values.fetch(name) if @values.key?(name)
        return @local.fetch(name) if @local.key?(name)

        raise KeyError, "unknown hoist: #{name}" unless definition
        if @materializing.include?(name)
          raise Error, "circular local hoist dependency: #{(@materializing + [name]).join(' -> ')}"
        end

        FactoryHoist.stats.increment(:deoptimizations)
        @materializing << name
        begin
          @local[name] = definition.materialize(ExampleMaterializationContext.new(self, @example))
        ensure
          @materializing.pop
        end
      end

      def defined?(name)
        @definitions.key?(name)
      end

    end

    class ExampleMaterializationContext
      def initialize(values, example)
        @values = values
        @example = example
      end

      def [](name)
        @values.fetch(name)
      end

      def __factory_hoist_evaluate__(&block)
        @example.instance_exec(&block)
      end

      def method_missing(name, *args, **kwargs, &block)
        return @values.fetch(name) if args.empty? && kwargs.empty? && @values.defined?(name)
        return @example.__send__(name, *args, **kwargs, &block) if @example.respond_to?(name, true)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @values.defined?(name) || @example.respond_to?(name, true) || super
      end
    end
  end
end
