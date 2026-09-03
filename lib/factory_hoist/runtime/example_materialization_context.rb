# frozen_string_literal: true

module FactoryHoist
  module Runtime
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
