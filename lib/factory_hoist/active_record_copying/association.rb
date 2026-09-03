# frozen_string_literal: true

module FactoryHoist
  module ActiveRecordCopying
    Association = Struct.new(:target, :loaded)
  end
end
