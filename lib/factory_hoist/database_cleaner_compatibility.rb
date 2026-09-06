# frozen_string_literal: true

module FactoryHoist
  module DatabaseCleanerCompatibility
    module_function

    def warn_if_incompatible(io = $stderr)
      return unless defined?(::DatabaseCleaner)

      strategy = ::DatabaseCleaner[:active_record].strategy
      return unless strategy.class.name.end_with?("Truncation")

      io.puts "factory_hoist: DatabaseCleaner truncation removes hoisted rows; use transaction strategy"
    rescue StandardError
      nil
    end
  end
end
