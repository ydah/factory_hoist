# frozen_string_literal: true

class LocalConstructorRecord
end

RSpec.describe FactoryHoist::RSpecDSL do
  it "treats string and symbol declaration names as the same key" do
    group = Class.new do
      extend FactoryHoist::RSpecDSL

      def self.metadata
        {full_description: "duplicate declaration test"}
      end
    end
    group.hoist("company")

    expect { group.hoist(:company) }.to raise_error(FactoryHoist::DuplicateHoistError)
  end
end

FactoryBot.define do
  factory :local_constructor_record do
    initialize_with { new }
    skip_create
  end
end

RSpec.describe "FactoryHoist RSpec integration" do
  Record = Struct.new(:kind, :attributes)

  before(:context) do
    FactoryHoist.stats.reset!
    FactoryHoist.configuration.subxid_budget = 60
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
    FactoryHoist.configuration.subxid_budget = 60
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

RSpec.describe "FactoryHoist marshal failure fallback" do
  BadMarshal = Class.new do
    def marshal_dump
      raise "custom marshal failure"
    end
  end

  before(:context) do
    FactoryHoist.stats.reset!
    FactoryHoist.configuration.factory_adapter = lambda do |_strategy, _name, _traits, _attributes|
      BadMarshal.new
    end
  end

  hoist(:bad_marshal)

  it "deoptimizes custom marshal failures" do
    expect(bad_marshal).to be_a(BadMarshal)
    expect(FactoryHoist.stats.to_h[:deoptimizations]).to eq(1)
  end
end

RSpec.describe "FactoryHoist lazy scheduling" do
  before(:context) do
    FactoryHoist.stats.reset!
    FactoryHoist.configuration.subxid_budget = 60
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
    FactoryHoist.configuration.subxid_budget = 60
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

RSpec.describe "FactoryHoist example-local dependency fallback" do
  before(:context) do
    FactoryHoist.stats.reset!
    @created = Struct.new(:count).new(0)
    created = @created
    FactoryHoist.configuration.factory_adapter = lambda do |_strategy, name, _traits, attributes|
      created.count += 1
      Struct.new(:kind, :attributes).new(name, attributes)
    end
  end

  let(:local_state) { :example_local }
  hoist(:local_order) { {state: local_state} }

  it "materializes through the example when a declaration uses let" do
    expect(@created.count).to eq(0)
    expect(local_order.attributes[:state]).to eq(:example_local)
    expect(@created.count).to eq(1)
    expect(FactoryHoist.stats.to_h[:deoptimizations]).to eq(1)
  end
end

RSpec.describe "FactoryHoist example instance fallback" do
  before(:context) do
    FactoryHoist.stats.reset!
    FactoryHoist.configuration.factory_adapter = lambda do |_strategy, name, _traits, attributes|
      Struct.new(:kind, :attributes).new(name, attributes)
    end
  end
  before { @local_state = :from_example }

  hoist(:instance_order) { {state: @local_state} }

  it "evaluates instance-variable declarations on the example" do
    expect(instance_order.attributes[:state]).to eq(:from_example)
    expect(FactoryHoist.stats.to_h[:deoptimizations]).to eq(1)
  end
end

RSpec.describe "FactoryHoist dependency ordering" do
  before(:context) do
    FactoryHoist.configuration.factory_adapter = lambda do |_strategy, name, _traits, attributes|
      Struct.new(:kind, :attributes).new(name, attributes)
    end
  end

  hoist(:order) { {company: company} }
  hoist(:company)

  it "materializes dependencies independently of declaration order" do
    expect(order.attributes[:company].kind).to eq(:company)
  end
end

RSpec.describe "FactoryHoist context method collisions" do
  before(:context) do
    FactoryHoist.configuration.factory_adapter = lambda do |_strategy, name, _traits, attributes|
      Struct.new(:kind, :attributes).new(name, attributes)
    end
  end

  hoist(:fetch)
  hoist(:evaluate)
  hoist(:dependent) { {fetch: fetch, evaluate: evaluate} }

  it "allows internal context method names as declaration keys" do
    expect(dependent.attributes[:fetch].kind).to eq(:fetch)
    expect(dependent.attributes[:evaluate].kind).to eq(:evaluate)
  end
end

RSpec.describe "FactoryHoist custom persistence fallback" do
  before(:context) do
    FactoryHoist.configuration.factory_adapter = nil
  end
  before { FactoryHoist.stats.reset! }

  hoist(:constructor_record, :local_constructor_record)
  hoist(:first_constructor, :local_constructor_record) { {other: second_constructor} }
  hoist(:second_constructor, :local_constructor_record) { {other: first_constructor} }

  it "deoptimizes initialize_with and to_create definitions" do
    expect(constructor_record).to be_a(LocalConstructorRecord)
    expect(FactoryHoist.stats.to_h[:deoptimizations]).to eq(1)
  end

  it "reports circular local dependencies without overflowing the stack" do
    expect { first_constructor }.to raise_error(FactoryHoist::MaterializationError, /circular local/)
  end
end
