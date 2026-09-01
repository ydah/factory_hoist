# frozen_string_literal: true

require_relative "compatibility"

module FactoryHoist
  module RSpecDSL
    def hoist(name, factory = name, *traits, **attributes, &block)
      definitions = if instance_variable_defined?(:@factory_hoist_definitions)
        @factory_hoist_definitions
      else
        @factory_hoist_definitions = {}
      end
      raise DuplicateHoistError, "hoist(:#{name}) is already declared in this group" if definitions.key?(name)

      node_path = metadata[:full_description]
      definitions[name] = Definition.new(name, factory, traits.freeze, attributes.freeze, block, node_path)
      define_method(name) { Runtime.current.fetch(self, name) }
      install_factory_hoist_hooks unless instance_variable_defined?(:@factory_hoist_hooks_installed)
    end

    private

    def install_factory_hoist_hooks
      @factory_hoist_hooks_installed = true
      group = self
      before(:context) do
        next unless self.class.equal?(group)

        Runtime.current.enter(group, group.instance_variable_get(:@factory_hoist_definitions))
      end
      after(:context) do
        next unless self.class.equal?(group)

        Runtime.current.leave(group)
      end
    end
  end

  ::RSpec::Core::ExampleGroup.extend(RSpecDSL)
  ::RSpec.configure do |config|
    config.before(:suite) { Compatibility.warn_for_database_cleaner }
    config.around(:each) { |example| Runtime.current.around_example(example) }
  end
end
