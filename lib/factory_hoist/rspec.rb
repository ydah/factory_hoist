# frozen_string_literal: true

require_relative "compatibility"
require_relative "scheduler"

module FactoryHoist
  module RSpecDSL
    def hoist(name, factory = name, *traits, **attributes, &block)
      name = name.to_sym
      definitions = if instance_variable_defined?(:@factory_hoist_definitions)
        @factory_hoist_definitions
      else
        @factory_hoist_definitions = {}
      end
      raise DuplicateHoistError, "hoist(:#{name}) is already declared in this group" if definitions.key?(name)

      node_path = metadata[:full_description]
      definition = Definition.new(name, factory, traits.freeze, attributes.freeze, block, node_path)
      definitions[name] = definition
      define_method(name) do
        Runtime.current.fetch(self, name, definition, Scheduler.definitions_for(self.class))
      end
    end
  end

  ::RSpec::Core::ExampleGroup.extend(RSpecDSL)
  ::RSpec.configure do |config|
    config.before(:suite) do
      Compatibility.warn_for_database_cleaner
      Scheduler.install!
    end
    config.around(:each) do |example|
      local = !Scheduler.definitions_for(example.example_group).empty?
      Runtime.current.around_example(example, local: local)
    end
  end
end
