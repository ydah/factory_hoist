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

      factory.build_class.transaction(requires_new: true) do
        factory.build_class.insert_all!(rows)
      end
    rescue StandardError => error
      index = failing_row(factory&.build_class, rows || [])
      location = index ? " at row #{index}" : ""
      raise BulkWriteError, "#{name} bulk insert failed#{location}: #{error.message}", cause: error
    end

    def failing_row(model, rows)
      return unless model&.respond_to?(:transaction)

      failed = nil
      model.transaction(requires_new: true) do
        rows.each_with_index do |row, index|
          model.insert_all!([row])
        rescue StandardError
          failed = index
          raise ::ActiveRecord::Rollback
        end
        raise ::ActiveRecord::Rollback
      end
      failed
    rescue StandardError
      nil
    end
    private_class_method :failing_row
  end
end
