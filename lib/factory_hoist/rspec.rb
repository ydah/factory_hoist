# frozen_string_literal: true

require_relative "database_cleaner_compatibility"
require_relative "rspec/hoistable"
require_relative "rspec/scheduler"

module FactoryHoist
  module RSpec
    ::RSpec::Core::ExampleGroup.extend(Hoistable)
    ::RSpec.configure do |config|
      config.before(:suite) do
        DatabaseCleanerCompatibility.warn_for_database_cleaner
        Scheduler.install!
      end
      config.around(:each) do |example|
        local = !Scheduler.definitions_for(example.example_group).empty?
        Runtime.current.around_example(example, local: local)
      end
    end
  end
end
