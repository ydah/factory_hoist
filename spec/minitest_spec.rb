# frozen_string_literal: true

require "minitest"
require "factory_hoist/minitest"

RSpec.describe FactoryHoist::MinitestDSL do
  let(:test_class) do
    Class.new(Minitest::Test) do
      hoist(:company)
      hoist(:user) { {company: company} }

      def test_placeholder; end
    end
  end

  before do
    FactoryHoist.stats.reset!
    FactoryHoist.configuration.factory_adapter = lambda do |_strategy, name, _traits, attributes|
      Struct.new(:name, :attributes).new(name, attributes)
    end
  end

  it "provides memoized, per-test values with dependency identity" do
    test = test_class.new(:test_placeholder)

    expect(test.user.attributes[:company]).to equal(test.company)
    expect(FactoryHoist.stats.to_h).to include(deoptimizations: 2)
  end

  it "rejects duplicate declarations in one class" do
    expect { test_class.hoist(:company) }.to raise_error(FactoryHoist::DuplicateHoistError)
  end
end
