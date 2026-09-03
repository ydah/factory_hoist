# frozen_string_literal: true

module FactoryHoist
  module Runtime
    class ExampleValueStore
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
  end
end
