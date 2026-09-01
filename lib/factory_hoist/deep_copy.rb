# frozen_string_literal: true

module FactoryHoist
  module DeepCopy
    module_function

    def call(object)
      Marshal.load(Marshal.dump(object))
    end
  end
end
