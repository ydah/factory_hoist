# frozen_string_literal: true

require_relative "minitest/example_value_store"
require_relative "minitest/example_value_access"
require_relative "minitest/hoistable"

module FactoryHoist
  module Minitest
    def self.install!
      return unless defined?(::Minitest::Test)
      return if ::Minitest::Test.singleton_class < Hoistable

      ::Minitest::Test.extend(Hoistable)
      ::Minitest::Test.include(ExampleValueAccess)
    end
  end
end

FactoryHoist::Minitest.install!
