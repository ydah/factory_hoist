# frozen_string_literal: true

require "factory_hoist/fast_build"

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

class FastBuildUser
  attr_accessor :first_name, :last_name, :email
end

class ReloadableFastBuildRecord
  attr_accessor :name
end

class RequiredConstructorRecord
  attr_reader :name

  def initialize(name:)
    @name = name
  end
end

FactoryBot.define do
  factory :fast_build_user do
    first_name { "Ada" }
    last_name { "Lovelace" }
    email { "#{first_name.downcase}.#{last_name.downcase}@example.test" }
  end

  factory :callback_fast_build_user, class: FastBuildUser do
    first_name { "before" }
    after(:build) { |user| user.first_name = "after" }
  end

  factory :reloadable_fast_build_record do
    name { "current" }
  end

  factory :required_constructor_record do
    name { "fallback" }
    initialize_with { new(name: name) }
  end
end

RSpec.describe FactoryHoist::FastBuild do
  before do
    FactoryHoist.configuration.factory_adapter = nil
    described_class.reset!
  end

  it "builds simple FactoryBot definitions through compiled attribute methods" do
    user = FactoryHoist.build(:fast_build_user, first_name: "Grace")

    expect(user).to be_a(FastBuildUser)
    expect(user.email).to eq("grace.lovelace@example.test")
    expect(File).to exist(described_class.compiled_source(:fast_build_user))
  end

  it "falls back to FactoryBot when callbacks affect build semantics" do
    expect(FactoryHoist.build(:callback_fast_build_user).first_name).to eq("after")
  end

  it "falls back for factories with required constructors" do
    expect(FactoryHoist.build(:required_constructor_record).name).to eq("fallback")
  end

  it "resolves model constants again after reload" do
    expect(FactoryHoist.build(:reloadable_fast_build_record)).to be_a(ReloadableFastBuildRecord)
    Object.send(:remove_const, :ReloadableFastBuildRecord)
    Object.const_set(:ReloadableFastBuildRecord, Class.new { attr_accessor :name })
    described_class.reload!

    expect(FactoryHoist.build(:reloadable_fast_build_record)).to be_a(ReloadableFastBuildRecord)
  end
end
