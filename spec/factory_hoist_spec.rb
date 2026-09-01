# frozen_string_literal: true

require "factory_hoist/fast_build"
require "faker"

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
    yielded = []
    built = described_class.build(:user, :admin, active: true) { |record| yielded << record }
    created = described_class.create(:user) { |record| yielded << record }

    expect(built).to eq(
      strategy: :build,
      name: :user,
      traits: [:admin],
      attributes: {active: true}
    )
    expect(created).to include(strategy: :create)
    expect(yielded).to eq([built, created])
  end

  it "builds lists without requiring an adapter-specific list API" do
    built = []
    created = []

    expect(described_class.build_list(:user, 2) { |record, index| built << [record, index] }.size).to eq(2)
    expect(described_class.create_list(:user, 3) { |record, index| created << [record, index] }.size).to eq(3)
    expect(built.map(&:last)).to eq([0, 1])
    expect(created.map(&:last)).to eq([0, 1, 2])
  end

  it "derives stable, node-specific seeds" do
    seed = FactoryHoist::Runtime.seed("orders paid", :order)

    expect(seed).to eq(FactoryHoist::Runtime.seed("orders paid", :order))
    expect(seed).not_to eq(FactoryHoist::Runtime.seed("orders refunded", :order))
  end

  it "uses a deterministic PCG random stream" do
    canonical = FactoryHoist::PCG32.new(42, 54)
    expect(Array.new(3) { canonical.rand(1 << 32) }).to eq(
      [2_707_161_783, 2_068_313_097, 3_122_475_824]
    )
    first = FactoryHoist::PCG32.new(123)

    expect(first.rand(3..5)).to be_between(3, 5)
    expect(first.bytes(4).bytesize).to eq(4)
    expect { first.rand(5...5) }.to raise_error(ArgumentError)
    expect(first.rand((1 << 32) + 1)).to be_between(0, 1 << 32)
    expect(first.rand(2.0..10.0)).to be_between(2.0, 10.0)
  end

  it "supports Faker's full random input surface deterministically" do
    generate = lambda do
      [
        Faker::Beer.alcohol,
        Faker::Code.npi,
        Faker::Date.between(from: Date.new(2020, 1, 1), to: Date.new(2030, 1, 1)),
        Faker::Time.between(from: Time.at(0), to: Time.at(1_000))
      ]
    end
    first = described_class.with_seed(123, &generate)
    second = described_class.with_seed(123, &generate)

    expect(second).to eq(first)
  end

  it "scopes deterministic PCG state through build and reset" do
    faker_config = Class.new do
      class << self
        attr_accessor :random
      end
    end
    stub_const("Faker::Config", faker_config)
    original = Random.new
    faker_config.random = original
    described_class.configuration.factory_adapter = lambda do |_strategy, _name, _traits, _attributes|
      Faker::Config.random.rand(1 << 32)
    end

    first = Array.new(2) { described_class.build(:user) }
    described_class.reset!
    described_class.configuration.factory_adapter = lambda do |_strategy, _name, _traits, _attributes|
      Faker::Config.random.rand(1 << 32)
    end

    expect(Array.new(2) { described_class.build(:user) }).to eq(first)
    expect(Faker::Config.random).to equal(original)
  end

  it "isolates Faker random sources between threads" do
    faker_config = Class.new do
      class << self
        attr_accessor :random
      end
    end
    stub_const("Faker::Config", faker_config)
    entered = Queue.new
    attempted = Queue.new
    release = Queue.new
    first = Thread.new { described_class.with_seed(1) { entered << 1; release.pop } }
    expect(entered.pop).to eq(1)
    second = Thread.new do
      attempted << true
      described_class.with_seed(2) { entered << 2 }
    end
    attempted.pop

    expect { entered.pop(true) }.to raise_error(ThreadError)
    release << true
    first.join
    second.join
    expect(entered.pop).to eq(2)
  ensure
    release << true if first&.alive?
    first&.join
    second&.join
  end

  it "reports factory usage statistics" do
    described_class.stats.increment(:references, 2)
    described_class.stats.increment(:deoptimizations)
    described_class.stats.record_reference("orders user")

    expect(described_class.stats.to_h).to include(
      references: 2,
      deoptimizations: 1,
      degradation_rate: 0.5,
      reference_counts: {"orders user" => 1}
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

  def model_prefix
    "model"
  end
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

class FastBuildChild
  attr_accessor :persisted
end

class FastBuildParent
  attr_accessor :child
end

class ReservedFastBuildRecord
  attr_accessor :build
end

class AliasFastBuildChild
  attr_accessor :marker
end

class AliasFastBuildParent
  attr_accessor :child, :child_id
end

class KeywordFastBuildRecord
  attr_accessor :if, :Foo
end

FactoryBot.define do
  factory :fast_build_user do
    first_name { "Ada" }
    last_name { "Lovelace" }
    email { "#{first_name.downcase}.#{last_name.downcase}@example.test" }
  end

  factory :model_method_fast_build_user, class: FastBuildUser do
    first_name { model_prefix }
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

  factory :broken_fast_build_user, class: FastBuildUser do
    first_name { raise "compiled attribute failure" }
  end

  sequence(:fast_build_failure_probe)
  factory :name_error_fast_build_user, class: FastBuildUser do
    first_name { generate(:fast_build_failure_probe) }
    last_name { MissingFastBuildConstant }
  end

  factory :fast_build_child do
    to_create { |child| child.persisted = true }
  end
  factory :fast_build_parent do
    association :child, factory: :fast_build_child
  end
  factory :reserved_fast_build_record do
    build { "attribute value" }
  end
  factory :"../unsafe fast build", class: FastBuildUser do
    first_name { "safe" }
  end
  sequence(:fast_build_alias_probe)
  factory :alias_fast_build_child do
    marker { generate(:fast_build_alias_probe) }
  end
  factory :alias_fast_build_parent do
    association :child, factory: :alias_fast_build_child
    child_id { 0 }
  end
  factory :keyword_fast_build_record do
    add_attribute(:if) { "value" }
    add_attribute(:Foo) { "uppercase" }
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

  it "keeps the generated source in compiled backtraces" do
    expect { FactoryHoist.build(:broken_fast_build_user) }.to raise_error do |error|
      expect(error.backtrace).to include(a_string_including("/factory_hoist/broken_fast_build_user_"))
    end
  end

  it "evaluates model instance methods like FactoryBot" do
    expect(FactoryHoist.build(:model_method_fast_build_user).first_name).to eq("model")
  end

  it "does not retry evaluator NameErrors through FactoryBot" do
    FactoryBot.rewind_sequence(:fast_build_failure_probe)

    expect { FactoryHoist.build(:name_error_fast_build_user) }.to raise_error(NameError)
    expect(FactoryBot.generate(:fast_build_failure_probe)).to eq(2)
  end

  it "honors FactoryBot association strategy configuration" do
    previous = FactoryBot.use_parent_strategy
    FactoryBot.use_parent_strategy = false

    expect(FactoryHoist.build(:fast_build_parent).child.persisted).to be(true)
  ensure
    FactoryBot.use_parent_strategy = previous
  end

  it "falls back when an attribute conflicts with evaluator methods" do
    expect(FactoryHoist.build(:reserved_fast_build_record).build).to eq("attribute value")
    expect(described_class.compiled_source(:reserved_fast_build_record)).to be_nil
  end

  it "uses safe process-specific generated paths" do
    FactoryHoist.build(:"../unsafe fast build")
    source = described_class.compiled_source(:"../unsafe fast build")

    expect(File.dirname(source)).to eq(File.join(Dir.tmpdir, "factory_hoist"))
    expect(File.basename(source)).to include("_#{Process.pid}_")
  end

  it "caps generated filenames for long factory names" do
    name = ("long_factory_" + ("x" * 300)).to_sym
    FactoryBot.define do
      factory name, class: FastBuildUser do
        first_name { "long" }
      end
    end

    expect(FactoryHoist.build(name).first_name).to eq("long")
    expect(File.basename(described_class.compiled_source(name)).bytesize).to be < 255
  end

  it "falls back when an override aliases an association" do
    FactoryBot.rewind_sequence(:fast_build_alias_probe)

    parent = FactoryHoist.build(:alias_fast_build_parent, child_id: 99)

    expect(parent.child).to be_nil
    expect(parent.child_id).to eq(99)
    expect(FactoryBot.generate(:fast_build_alias_probe)).to eq(1)
  end

  it "falls back when attribute names cannot be emitted as local variables" do
    record = FactoryHoist.build(:keyword_fast_build_record)

    expect(record.public_send(:if)).to eq("value")
    expect(record.public_send(:Foo)).to eq("uppercase")
    expect(described_class.compiled_source(:keyword_fast_build_record)).to be_nil
  end
end

RSpec.describe FactoryHoist::Runtime::Scope do
  it "captures its ancestor scopes instead of retaining descendant mutations" do
    ancestors = []
    scope = described_class.new(Object.new, {}, ancestors)

    ancestors << Object.new

    expect(scope.instance_variable_get(:@ancestors)).to be_empty
  end
end
