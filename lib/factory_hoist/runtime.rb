# frozen_string_literal: true

require "digest"
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
      Thread.current[THREAD_KEY] = nil
    end

    def seed(node_path, key, index = 0)
      input = [FactoryHoist.configuration.suite_seed, node_path, key, index].join("\0")
      Digest::SHA256.digest(input).unpack1("Q>")
    end

    class Session
      def initialize
        @scopes = []
        @transaction = Transaction.new
        @examples_since_begin = 0
      end

      def enter(group, definitions)
        if @scopes.empty?
          @transaction.begin_outer
          @examples_since_begin = 0
        end
        scope = Scope.new(group, definitions, @scopes)
        @transaction.create_savepoint(scope.savepoint)
        @scopes << scope
        scope.materialize!
      rescue Exception # rubocop:disable Lint/RescueException
        @scopes.pop if @scopes.last == scope
        @transaction.rollback_savepoint(scope.savepoint) if scope
        @transaction.rollback_outer if @scopes.empty?
        raise
      end

      def leave(group)
        scope = @scopes.pop
        return unless scope
        raise Error, "hoist scope mismatch" unless scope.group.equal?(group)

        @transaction.rollback_savepoint(scope.savepoint)
        if @scopes.empty?
          @transaction.rollback_outer
          @examples_since_begin = 0
        end
      end

      def around_example(example)
        return example.run if @scopes.empty?

        rebuild_if_needed
        savepoint = "factory_hoist_example_#{example.object_id}"
        @transaction.create_savepoint(savepoint)
        @examples_since_begin += 1
        example.run
      ensure
        @transaction.rollback_savepoint(savepoint) if savepoint
      end

      def fetch(example_instance, name)
        FactoryHoist.stats.increment(:references)
        state = example_instance.instance_variable_get(:@__factory_hoist_values)
        unless state
          state = ExampleValues.new(@scopes)
          example_instance.instance_variable_set(:@__factory_hoist_values, state)
        end
        state.fetch(name)
      end

      private

      def rebuild_if_needed
        budget = FactoryHoist.configuration.subxid_budget
        return unless @transaction.owned? && budget.positive? && @examples_since_begin >= budget

        @transaction.rollback_outer
        @transaction.begin_outer
        @scopes.each do |scope|
          @transaction.create_savepoint(scope.savepoint)
          scope.materialize!
        end
        @examples_since_begin = 0
        FactoryHoist.stats.increment(:transaction_rebuilds)
      end
    end

    class Scope
      attr_reader :definitions, :group, :values

      def initialize(group, definitions, ancestors)
        @group = group
        @definitions = definitions
        @ancestors = ancestors
        @values = {}
      end

      def savepoint
        @savepoint ||= "factory_hoist_group_#{group.object_id}"
      end

      def materialize!
        @values = {}
        context = MaterializationContext.new(@ancestors, self)
        @definitions.each_value do |definition|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @values[definition.name] = definition.materialize(context)
          FactoryHoist.stats.increment(:materializations)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          FactoryHoist.stats.record_cost("#{definition.node_path} #{definition.name}", elapsed)
        end
      end
    end

    class MaterializationContext
      def initialize(ancestors, current)
        @scopes = ancestors + [current]
      end

      def [](name)
        fetch(name)
      end

      def method_missing(name, ...)
        return fetch(name) if available?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        available?(name) || super
      end

      private

      def available?(name)
        @scopes.reverse_each.any? { |scope| scope.values.key?(name) }
      end

      def fetch(name)
        scope = @scopes.reverse_each.find { |candidate| candidate.values.key?(name) }
        return scope.values.fetch(name) if scope

        raise KeyError, "unknown hoist: #{name}"
      end
    end

    class ExampleValues
      def initialize(scopes)
        @scopes = scopes.dup
        @values = copy_shared_values
        @local = {}
      end

      def fetch(name)
        return @values.fetch(name) if @values.key?(name)
        return @local.fetch(name) if @local.key?(name)

        definition = visible_definitions.fetch(name) { raise KeyError, "unknown hoist: #{name}" }
        FactoryHoist.stats.increment(:deoptimizations)
        @local[name] = definition.materialize(ExampleMaterializationContext.new(self))
      end

      def defined?(name)
        visible_definitions.key?(name)
      end

      private

      def copy_shared_values
        copyable = visible_values.select do |_name, value|
          DeepCopy.call(value)
          true
        rescue TypeError
          false
        end
        DeepCopy.call(copyable)
      rescue TypeError
        {}
      end

      def visible_values
        @scopes.each_with_object({}) { |scope, values| values.merge!(scope.values) }
      end

      def visible_definitions
        @scopes.each_with_object({}) { |scope, definitions| definitions.merge!(scope.definitions) }
      end
    end

    class ExampleMaterializationContext
      def initialize(values)
        @values = values
      end

      def [](name)
        @values.fetch(name)
      end

      def method_missing(name, ...)
        @values.fetch(name)
      rescue KeyError
        super
      end

      def respond_to_missing?(name, include_private = false)
        @values.defined?(name) || super
      end
    end
  end
end
