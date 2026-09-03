# frozen_string_literal: true

module FactoryHoist
  module Minitest
    module Hoistable
      def hoist(name, factory = name, *traits, **attributes, &block)
        name = name.to_sym
        definitions = if instance_variable_defined?(:@factory_hoist_definitions)
          @factory_hoist_definitions
        else
          @factory_hoist_definitions = {}
        end
        raise DuplicateHoistError, "hoist(:#{name}) is already declared in this class" if definitions.key?(name)

        definition = Definition.new(name, factory, traits.freeze, attributes.freeze, block, to_s)
        definitions[name] = definition
        define_method(name) { factory_hoist_local_values.fetch(name) }
      end

      def factory_hoist_definitions
        inherited = superclass.respond_to?(:factory_hoist_definitions) ? superclass.factory_hoist_definitions : {}
        inherited.merge(instance_variable_get(:@factory_hoist_definitions) || {})
      end
    end
  end
end
