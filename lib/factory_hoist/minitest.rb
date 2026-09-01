# frozen_string_literal: true

module FactoryHoist
  module MinitestDSL
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

  class MinitestValues
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

  module MinitestInstance
    private

    def factory_hoist_local_values
      @factory_hoist_local_values ||= MinitestValues.new(self)
    end
  end

  def self.install_minitest!
    return unless defined?(::Minitest::Test)
    return if ::Minitest::Test.singleton_class < MinitestDSL

    ::Minitest::Test.extend(MinitestDSL)
    ::Minitest::Test.include(MinitestInstance)
  end
end

FactoryHoist.install_minitest!
