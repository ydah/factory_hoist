# frozen_string_literal: true

RSpec.describe FactoryHoist do
  before do
    described_class.reset!
    described_class.configure do |config|
      config.factory_adapter = lambda do |strategy, name, traits, attributes|
        {strategy: strategy, name: name, traits: traits, attributes: attributes}
      end
    end
  end

  it "has a version number" do
    expect(FactoryHoist::VERSION).not_to be_nil
  end

  it "delegates build and create calls to the configured adapter" do
    expect(described_class.build(:user, :admin, active: true)).to eq(
      strategy: :build,
      name: :user,
      traits: [:admin],
      attributes: {active: true}
    )
    expect(described_class.create(:user)).to include(strategy: :create)
  end

  it "builds lists without requiring an adapter-specific list API" do
    expect(described_class.build_list(:user, 2).size).to eq(2)
    expect(described_class.create_list(:user, 3).size).to eq(3)
  end

  it "derives stable, node-specific seeds" do
    seed = FactoryHoist::Runtime.seed("orders paid", :order)

    expect(seed).to eq(FactoryHoist::Runtime.seed("orders paid", :order))
    expect(seed).not_to eq(FactoryHoist::Runtime.seed("orders refunded", :order))
  end

  it "reports factory usage statistics" do
    described_class.stats.increment(:references, 2)
    described_class.stats.increment(:deoptimizations)

    expect(described_class.stats.to_h).to include(
      references: 2,
      deoptimizations: 1,
      degradation_rate: 0.5
    )
  end

  it "reports the declaration node when materialization fails" do
    described_class.configuration.factory_adapter = ->(*) { raise "database unavailable" }
    definition = FactoryHoist::Definition.new(:user, :user, [], {}, nil, "orders paid")

    expect { definition.materialize(Object.new) }
      .to raise_error(FactoryHoist::MaterializationError, /orders paid hoist\(:user\).*database unavailable/)
  end

  it "uses FactoryBot as the default backend" do
    described_class.configuration.factory_adapter = nil

    expect { described_class.create(:user) }
      .to raise_error(KeyError, /Factory not registered/)
  end
end
