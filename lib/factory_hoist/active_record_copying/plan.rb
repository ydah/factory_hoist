# frozen_string_literal: true

module FactoryHoist
  module ActiveRecordCopying
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
