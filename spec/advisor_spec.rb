# frozen_string_literal: true

require "stringio"
require "tempfile"

RSpec.describe FactoryHoist::Advisor do
  it "reports unused declarations and repeated factory calls" do
    Tempfile.create(["factory_hoist", "_spec.rb"]) do |file|
      file.write(<<~RUBY)
        hoist(:unused)
        create(:user)
        create(:user)
      RUBY
      file.flush
      output = StringIO.new

      described_class.new([file.path]).print(output)

      expect(output.string).to include("unused hoist :unused", "repeated create(:user) x2")
    end
  end

  it "does not merge calls with different arguments" do
    Tempfile.create(["factory_hoist", "_spec.rb"]) do |file|
      file.write("create(:user, active: true)\ncreate(:user, active: false)\n")
      file.flush
      output = StringIO.new

      described_class.new([file.path]).print(output)

      expect(output.string).not_to include("repeated create(:user)")
    end
  end

  it "does not report a materialized dependency as unused" do
    FactoryHoist.stats.reset!
    FactoryHoist.stats.increment(:materializations)
    FactoryHoist.stats.record_cost("orders company", 0.1)
    FactoryHoist.stats.record_reference("orders company")
    output = StringIO.new

    described_class.new([]).print(output)

    expect(output.string).not_to include("unused at runtime")
  end
end
