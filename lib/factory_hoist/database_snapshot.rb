# frozen_string_literal: true

require "digest"
require "set"

module FactoryHoist
  module DatabaseSnapshot
    module_function

    def call(scopes)
      records = records_in(scopes.flat_map { |scope| scope.values.values })
      return if records.empty?

      rows = records.sort_by { |record| [record.class.name, record.id.to_s] }.map do |record|
        primary_key = record.class.primary_key
        [record.class.name, record.id, record.class.unscoped.find_by(primary_key => record.id)&.attributes]
      end
      Digest::SHA256.hexdigest(Marshal.dump(rows))
    end

    def records_in(objects)
      return [] unless defined?(::ActiveRecord::Base)

      seen = Set.new
      records = []
      visit = lambda do |object|
        return if object.nil? || seen.include?(object.object_id)

        seen << object.object_id
        case object
        when ::ActiveRecord::Base
          records << object if object.persisted?
          associations = object.instance_variable_get(:@association_cache) || {}
          associations.each_value { |association| visit.call(association.target) }
        when Array
          object.each { |value| visit.call(value) }
        when Hash
          object.each_value { |value| visit.call(value) }
        end
      end
      objects.each { |object| visit.call(object) }
      records
    end
    private_class_method :records_in
  end
end
