# frozen_string_literal: true

module FactoryHoist
  module Minitest
    module ExampleValueAccess
      private

      def factory_hoist_local_values
        @factory_hoist_local_values ||= ExampleValueStore.new(self)
      end
    end
  end
end
