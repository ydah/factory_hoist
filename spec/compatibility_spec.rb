# frozen_string_literal: true

require "stringio"
require "factory_hoist/compatibility"

RSpec.describe FactoryHoist::Compatibility do
  it "warns when DatabaseCleaner uses truncation" do
    stub_const("ExampleTruncation", Class.new)
    cleaner = Object.new
    cleaner.define_singleton_method(:strategy) { ExampleTruncation.new }
    database_cleaner = Object.new
    database_cleaner.define_singleton_method(:[]) { |_orm| cleaner }
    stub_const("DatabaseCleaner", database_cleaner)
    output = StringIO.new

    described_class.warn_for_database_cleaner(output)

    expect(output.string).to include("use transaction strategy")
  end
end
