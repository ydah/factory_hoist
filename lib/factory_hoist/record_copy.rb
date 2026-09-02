# frozen_string_literal: true

module FactoryHoist
  # Replays an ActiveRecord object graph without Marshal.
  # The graph shape is analysed once per group materialization; each example
  # then pays for lightweight state replay and association rewiring.
  module RecordCopy
    Unsupported = Class.new(StandardError)
    Association = Struct.new(:target, :loaded)
    Node = Struct.new(:klass, :attributes, :new_record, :associations, :extra_ivars, :previous_changes)

    # ActiveRecord rebuilds these itself. Other ivars, such as callback flags,
    # are captured once and replayed for every copy.
    REPLAYED_IVARS = %i[@attributes @association_cache @new_record @destroyed].freeze

    # Transient per-operation bookkeeping that ActiveRecord rebuilds on demand;
    # a freshly instantiated record does not carry it either.
    TRANSIENT_IVARS = %i[
      @context_for_validation @validation_context @errors
      @mutations_from_database @mutations_before_last_save
    ].freeze

    module_function

    def plan(values)
      return nil unless defined?(::ActiveRecord::Base)

      slots = {}
      nodes = []
      layout = values.transform_values { |value| visit(value, slots, nodes) }
      Plan.new(nodes, layout)
    rescue StandardError
      nil
    end

    def visit(record, slots, nodes)
      key = record.object_id
      return slots[key] if slots.key?(key)
      raise Unsupported unless record.is_a?(::ActiveRecord::Base)
      raise Unsupported unless record.class.name
      raise Unsupported unless record.singleton_methods(false).empty?
      raise Unsupported if record.destroyed? || record.frozen?
      raise Unsupported if record.errors.any?
      raise Unsupported unless copyable_class?(record.class)

      slot = nodes.size
      slots[key] = slot
      extras = record.instance_variables - REPLAYED_IVARS - TRANSIENT_IVARS
      extras.reject! { |ivar| ivar.start_with?("@_") }
      extra_ivars = extras.to_h { |ivar| [ivar, record.instance_variable_get(ivar)] }
      raise Unsupported unless copyable_ivar?(extra_ivars)
      raise Unsupported if record.attributes.any? do |_name, value|
        value.is_a?(String) && contains_object?(extra_ivars, value)
      end
      node = Node.new(
        record.class, record.instance_variable_get(:@attributes), record.new_record?, {},
        extra_ivars, record.previous_changes
      )
      nodes << node
      record.class.reflect_on_all_associations.each do |reflection|
        next unless record.association_cached?(reflection.name)

        association = record.association(reflection.name)
        target = association.target
        next if !association.loaded? && (target.nil? || (target.respond_to?(:empty?) && target.empty?))

        target = if target.is_a?(Array)
          target.map { |element| visit(element, slots, nodes) }
        elsif target
          visit(target, slots, nodes)
        end
        node.associations[reflection.name] = Association.new(target, association.loaded?)
      end
      slot
    end

    def copyable_ivar?(value, seen = {})
      return true if value.nil? || value.equal?(true) || value.equal?(false) || value.is_a?(Symbol)
      return value.instance_variables.empty? if value.is_a?(Numeric) || value.is_a?(String)
      return true if seen[value.object_id]
      return false unless value.instance_variables.empty?

      seen[value.object_id] = true
      case value
      when Array then value.all? { |element| copyable_ivar?(element, seen) }
      when Hash then value.all? { |key, element| copyable_ivar?(key, seen) && copyable_ivar?(element, seen) }
      else false
      end
    end

    def contains_object?(value, target, seen = {})
      return true if value.equal?(target)
      return false if seen[value.object_id]

      seen[value.object_id] = true
      case value
      when Array then value.any? { |element| contains_object?(element, target, seen) }
      when Hash then value.any? do |key, element|
        contains_object?(key, target, seen) || contains_object?(element, target, seen)
      end
      else false
      end
    end

    # Attribute#dup only shallow-copies its value. Scalar mutable types are safe;
    # compound types (serialize, json, arrays, custom types) are not.
    def copyable_class?(klass)
      return false if klass._initialize_callbacks.any? || klass._find_callbacks.any?

      klass.attribute_types.none? do |_name, type|
        type.mutable? &&
          !type.is_a?(::ActiveModel::Type::String) &&
          !type.is_a?(::ActiveModel::Type::Binary) &&
          !type.is_a?(::ActiveModel::Type::DateTime) &&
          !type.is_a?(::ActiveModel::Type::Time)
      end
    rescue StandardError
      false
    end

    class Plan
      def initialize(nodes, layout)
        @nodes = nodes
        @layout = layout
        @extra_ivars = Marshal.dump(nodes.map(&:extra_ivars))
      end

      def call
        extra_ivars = Marshal.load(@extra_ivars)
        copies = @nodes.each_with_index.map do |node, index|
          copy = node.klass.allocate
          copy.init_with_attributes(node.attributes.deep_dup, node.new_record)
          extra_ivars.fetch(index).each { |ivar, value| copy.instance_variable_set(ivar, value) }
          replay_previous_changes(copy, node.previous_changes)
          copy
        end
        @nodes.each_with_index do |node, index|
          node.associations.each do |name, association|
            slots = association.target
            target = slots.is_a?(Array) ? slots.map { |slot| copies[slot] } : (slots && copies[slots])
            copy_association = copies[index].association(name)
            copy_association.target = target
            copy_association.instance_variable_set(:@loaded, false) unless association.loaded
          end
        end
        @layout.transform_values { |slot| copies[slot] }
      end

      private

      def replay_previous_changes(copy, previous_changes)
        return if previous_changes.empty?

        changes = previous_changes.deep_dup
        tracker = ::ActiveModel::ForcedMutationTracker.new(copy)
        tracker.instance_variable_set(:@forced_changes, changes.transform_values(&:first))
        tracker.instance_variable_set(:@finalized_changes, changes)
        copy.instance_variable_set(:@mutations_before_last_save, tracker)
      end
    end
  end
end
