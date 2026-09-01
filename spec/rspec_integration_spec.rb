# frozen_string_literal: true

RSpec.describe "FactoryHoist RSpec integration" do
  Record = Struct.new(:kind, :attributes)

  before(:context) do
    FactoryHoist.reset!
    @created = Hash.new(0)
    created = @created
    FactoryHoist.configure do |config|
      config.factory_adapter = lambda do |_strategy, name, _traits, attributes|
        created[name] += 1
        Record.new(name, attributes)
      end
    end
  end

  hoist(:company)

  it "materializes a declaration once and memoizes access per example" do
    expect(company).to equal(company)
    expect(@created[:company]).to eq(1)
  end

  it "returns an isolated copy to each example" do
    company.attributes[:changed] = true

    expect(company.attributes).to eq(changed: true)
    expect(@created[:company]).to eq(1)
  end

  it "does not leak a sibling example's in-memory mutation" do
    expect(company.attributes).to eq({})
  end

  context "with a dependent declaration" do
    hoist(:order) { {company: company, state: :paid} }

    it "preserves relationships while copying the visible object graph" do
      expect(order.attributes[:company]).to equal(company)
      expect(order.attributes[:state]).to eq(:paid)
      expect(@created).to include(company: 1, order: 1)
    end
  end
end

RSpec.describe "FactoryHoist deoptimization" do
  before(:context) do
    FactoryHoist.reset!
    @counts = {created: 0}
    counts = @counts
    FactoryHoist.configuration.factory_adapter = lambda do |_strategy, _name, _traits, _attributes|
      counts[:created] += 1
      proc {}
    end
  end

  hoist(:uncopyable)

  it "falls back to example-local generation for uncopyable values" do
    expect(uncopyable).to equal(uncopyable)
    expect(@counts[:created]).to eq(2)
    expect(FactoryHoist.stats.to_h[:deoptimizations]).to eq(1)
  end
end
