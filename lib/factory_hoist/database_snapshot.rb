# frozen_string_literal: true

require "digest"
require "set"

module FactoryHoist
  module DatabaseSnapshot
    module_function

    def call(scopes)
      records = records_in(scopes.flat_map { |scope| scope.values.values })
      return if records.empty?

      rows = records.map do |record|
        model = record.class.name || "table:#{record.class.table_name}"
        primary_keys = Array(record.class.primary_key)
        if primary_keys.empty?
          identity = record.attributes
          current = [identity, record.class.unscoped.where(identity).count]
        else
          identity = primary_keys.zip(Array(record.id)).to_h
          current = record.class.unscoped.find_by(identity)&.attributes
        end
        [model, record.id || identity, current]
      end.sort_by { |model, id, _attributes| [model, id.to_s] }
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
