# frozen_string_literal: true

module FactoryHoist
  module BulkWriter
    module_function

    def call(name, count, traits, attributes)
      unless defined?(::FactoryBot::Internal)
        raise FactoryUnavailableError, "unsafe_bulk_insert requires factory_bot"
      end

      factory = ::FactoryBot::Internal.factory_by_name(name)
      rows = Array.new(count) { ::FactoryBot.attributes_for(name, *traits, **attributes) }
      return [] if rows.empty?

      factory.build_class.insert_all!(rows)
    end
  end
end
