# frozen_string_literal: true

module FactoryHoist
  module Minitest
    module ExampleValueAccess
      private

      def factory_hoist_value_store
        @factory_hoist_value_store ||= ExampleValueStore.new(self)
      end
    end
  end
end
