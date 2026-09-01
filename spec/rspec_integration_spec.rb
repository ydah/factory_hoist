# frozen_string_literal: true

RSpec.describe "FactoryHoist RSpec integration" do
  Record = Struct.new(:kind, :attributes)

  before(:context) do
    FactoryHoist.stats.reset!
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
    FactoryHoist.stats.reset!
    @counts = Hash.new(0)
    counts = @counts
    FactoryHoist.configuration.factory_adapter = lambda do |_strategy, name, _traits, _attributes|
      counts[name] += 1
      name == :uncopyable ? proc {} : {name: name}
    end
  end

  hoist(:uncopyable)
  hoist(:copyable)

  it "deoptimizes only the uncopyable value" do
    expect(uncopyable).to equal(uncopyable)
    expect(copyable).to eq(name: :copyable)
    expect(@counts).to include(uncopyable: 2, copyable: 1)
    expect(FactoryHoist.stats.to_h[:deoptimizations]).to eq(1)
  end
end

RSpec.describe "FactoryHoist lazy scheduling" do
  before(:context) do
    FactoryHoist.stats.reset!
    @created = Hash.new(0)
    created = @created
    FactoryHoist.configuration.factory_adapter = lambda do |_strategy, name, _traits, attributes|
      created[name] += 1
      Record.new(name, attributes)
    end
  end

  hoist(:unused)
  hoist(:company)

  it "does not materialize declarations without a selected reference" do
    expect(@created).to eq({})
  end

  context "when only a descendant references a dependent declaration" do
    hoist(:order) { {company: company} }

    it "materializes both declarations at their descendant LCA" do
      expect(order.attributes[:company].kind).to eq(:company)
      expect(@created).to include(company: 1, order: 1)
      expect(@created[:unused]).to eq(0)
    end
  end
end

RSpec.describe "FactoryHoist dynamic reference fallback" do
  before(:context) do
    FactoryHoist.stats.reset!
    @created = Hash.new(0)
    created = @created
    FactoryHoist.configuration.factory_adapter = lambda do |_strategy, name, _traits, attributes|
      created[name] += 1
      Record.new(name, attributes)
    end
  end

  hoist(:dynamic)

  it "creates an unanalyzable dynamic reference locally" do
    expect(@created[:dynamic]).to eq(0)
    name = "dynamic".to_sym

    expect(public_send(name).kind).to eq(:dynamic)
    expect(@created[:dynamic]).to eq(1)
    expect(FactoryHoist.stats.to_h[:deoptimizations]).to eq(1)
  end
end
