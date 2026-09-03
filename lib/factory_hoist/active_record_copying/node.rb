# frozen_string_literal: true

module FactoryHoist
  module ActiveRecordCopying
    Node = Struct.new(:klass, :attributes, :new_record, :associations, :extra_ivars, :previous_changes)
  end
end
