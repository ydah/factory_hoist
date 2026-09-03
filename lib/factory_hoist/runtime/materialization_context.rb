# frozen_string_literal: true

module FactoryHoist
  module Runtime
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
  end
end
