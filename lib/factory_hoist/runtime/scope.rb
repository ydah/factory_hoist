# frozen_string_literal: true

module FactoryHoist
  module Runtime
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
  end
end
