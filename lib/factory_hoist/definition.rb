# frozen_string_literal: true

module FactoryHoist
  Definition = Data.define(:name, :factory, :traits, :attributes, :block, :node_path) do
    def materialize(context)
      dynamic_attributes = if block
        block.arity == 1 ? block.call(context) : context.evaluate(&block)
      else
        {}
      end
      unless dynamic_attributes.is_a?(Hash)
        raise ArgumentError, "hoist(:#{name}) block must return a Hash"
      end

      seed = Runtime.seed(node_path, name)
      FactoryHoist.with_seed(seed) do
        FactoryHoist.create(factory, *traits, **attributes, **dynamic_attributes)
      end
    rescue MaterializationError
      raise
    rescue StandardError => error
      raise MaterializationError,
        "#{node_path} hoist(:#{name}) failed: #{error.message}",
        cause: error
    end
  end
end
