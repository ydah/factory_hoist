# frozen_string_literal: true

module FactoryHoist
  module Minitest
    class ExampleValueStore
      def initialize(test)
        @test = test
        @values = {}
      end

      def fetch(name)
        FactoryHoist.stats.increment(:references)
        return @values[name] if @values.key?(name)

        definition = @test.class.factory_hoist_definitions.fetch(name)
        FactoryHoist.stats.record_reference("#{definition.node_path} #{name}")
        FactoryHoist.stats.increment(:deoptimizations)
        @values[name] = definition.materialize(self)
      end

      alias_method :[], :fetch

      def __factory_hoist_evaluate__(&block)
        @test.instance_exec(&block)
      end

      def method_missing(name, *args, **kwargs, &block)
        if args.empty? && kwargs.empty? && @test.class.factory_hoist_definitions.key?(name)
          return fetch(name)
        end
        return @test.__send__(name, *args, **kwargs, &block) if @test.respond_to?(name, true)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @test.class.factory_hoist_definitions.key?(name) || @test.respond_to?(name, true) || super
      end
    end
  end
end
