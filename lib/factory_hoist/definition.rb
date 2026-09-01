# frozen_string_literal: true

module FactoryHoist
  Definition = Data.define(:name, :factory, :traits, :attributes, :block, :node_path) do
    def materialize(context)
      dynamic_attributes = if block
        block.arity == 1 ? block.call(context) : context.instance_exec(&block)
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
    end
  end
end
