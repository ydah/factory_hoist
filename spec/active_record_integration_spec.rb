# frozen_string_literal: true

require "active_record"
require "factory_hoist/bulk_insertion"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.define do
  create_table :factory_hoist_users, force: true do |table|
    table.string :name, null: false
    table.datetime :last_seen_at
  end
  create_table :factory_hoist_memberships, id: false, force: true do |table|
    table.integer :account_id, null: false
    table.integer :user_id, null: false
    table.string :role, null: false
  end
  create_table :factory_hoist_documents, force: true do |table|
    table.json :payload
  end
  create_table :factory_hoist_preferences, force: true do |table|
    table.text :payload
  end
end

class FactoryHoistUser < ActiveRecord::Base
  has_many :memberships, class_name: "FactoryHoistMembership", foreign_key: :user_id, inverse_of: :user
end

class FactoryHoistMembership < ActiveRecord::Base
  self.primary_key = %i[account_id user_id]
  belongs_to :user, class_name: "FactoryHoistUser", inverse_of: :memberships
end

class FactoryHoistDocument < ActiveRecord::Base
end

class FactoryHoistPreference < ActiveRecord::Base
  serialize :payload, coder: JSON
end

class FactoryHoistCallbackUser < FactoryHoistUser
  after_initialize { @initialized_by_callback = true }
end

FactoryBot.define do
  factory :factory_hoist_user do
    name { "original" }
  end
end

RSpec.describe FactoryHoist::ValueCopying do
  after do
    FactoryHoistDocument.delete_all
    FactoryHoistPreference.delete_all
  end

  it "dumps a snapshot once and only loads it for each example" do
    value = {nested: [1]}
    allow(Marshal).to receive(:dump).and_call_original

    snapshot = described_class.snapshot(value: value)
    snapshot.call
    snapshot.call

    expect(Marshal).to have_received(:dump).once
  end

  it "falls back for compound mutable attributes and keeps them isolated" do
    [
      FactoryHoistDocument.create!(payload: {"items" => [1]}),
      FactoryHoistPreference.create!(payload: {"items" => [1]})
    ].each do |record|
      record.payload
      snapshot = described_class.snapshot(record: record)
      first = snapshot.call.fetch(:record)
      second = snapshot.call.fetch(:record)
      first.payload["items"] << 2

      expect(snapshot).to be_a(described_class::Snapshot)
      expect(second.payload).to eq("items" => [1])
      expect(record.payload).to eq("items" => [1])
    end
  end

  it "falls back when an ActiveRecord replay cannot be validated" do
    plan = Object.new
    plan.define_singleton_method(:call) { raise "unsupported replay" }
    allow(FactoryHoist::ActiveRecordCopying).to receive(:plan).and_return(plan)

    snapshot = described_class.snapshot(value: {nested: [1]})

    expect(snapshot.call).to eq(value: {nested: [1]})
  end
end

RSpec.describe FactoryHoist::ActiveRecordCopying do
  after do
    FactoryHoistMembership.delete_all
    FactoryHoistUser.delete_all
  end

  it "replays associations and callback ivars without sharing state" do
    user = FactoryHoistUser.create!(name: "graph", last_seen_at: Time.now)
    membership = user.memberships.create!(account_id: 1, role: "owner")
    user.memberships.load
    membership.user
    flag = {"items" => [1]}
    user.instance_variable_set(:@factory_flag, flag)
    membership.instance_variable_set(:@factory_flag, flag)
    snapshot = described_class.plan(user: user, membership: membership)

    first = snapshot.call
    second = snapshot.call
    first.fetch(:user).instance_variable_get(:@factory_flag)["items"] << 2

    expect(first.fetch(:user).memberships.first).to equal(first.fetch(:membership))
    expect(first.fetch(:membership).user).to equal(first.fetch(:user))
    expect(first.fetch(:user).instance_variable_get(:@factory_flag))
      .to equal(first.fetch(:membership).instance_variable_get(:@factory_flag))
    expect(second.fetch(:user).instance_variable_get(:@factory_flag)).to eq("items" => [1])
    expect(user.instance_variable_get(:@factory_flag)).to eq("items" => [1])
  end

  it "preserves dirty tracking without sharing previous changes" do
    user = FactoryHoistUser.create!(name: "before")
    original_changes = user.previous_changes
    user.name = "after"
    expect(user.association_cached?(:memberships)).to be(false)
    snapshot = described_class.plan(user: user)
    expect(user.association_cached?(:memberships)).to be(false)

    first = snapshot.call.fetch(:user)
    second = snapshot.call.fetch(:user)
    first.previous_changes.fetch("name").last << " changed"

    expect(first.changes).to eq("name" => ["before", "after"])
    expect(second.previous_changes).to eq(original_changes)
    expect(user.previous_changes).to eq(original_changes)
  end

  it "preserves a built association target before the collection is loaded" do
    user = FactoryHoistUser.create!(name: "pending association")
    FactoryHoistMembership.create!(user: user, account_id: 1, role: "persisted")
    membership = user.memberships.build(account_id: 2, role: "built")
    expect(user.association(:memberships)).not_to be_loaded

    copy = described_class.plan(user: user, membership: membership).call
    copied_user = copy.fetch(:user)

    expect(copied_user.association(:memberships).target.first).to equal(copy.fetch(:membership))
    expect(copied_user.association(:memberships)).not_to be_loaded
    expect(copied_user.memberships.map(&:role)).to contain_exactly("persisted", "built")
  end

  it "rejects record states and ivars it cannot faithfully replay" do
    record = FactoryHoistUser.create!(name: "destroyed")
    record.destroy!
    user = FactoryHoistUser.create!(name: "linked ivar")
    membership = user.memberships.create!(account_id: 1, role: "owner")
    user.instance_variable_set(:@callback_link, {record: membership})
    aliased = FactoryHoistUser.create!(name: "aliased ivar")
    aliased.instance_variable_set(:@callback_flag, aliased.name)
    decorated = FactoryHoistUser.new(name: "decorated")
    decorated.define_singleton_method(:decorated?) { true }
    invalid = FactoryHoistUser.new
    invalid.errors.add(:name, "invalid")
    callback_record = FactoryHoistCallbackUser.new(name: "callback")

    expect(described_class.plan(record: record)).to be_nil
    expect(described_class.plan(user: user, membership: membership)).to be_nil
    expect(described_class.plan(record: aliased)).to be_nil
    expect(described_class.plan(record: decorated)).to be_nil
    expect(described_class.plan(record: invalid)).to be_nil
    expect(described_class.plan(record: callback_record)).to be_nil
  end
end

RSpec.describe FactoryHoist::Runtime::Session do
  it "reuses snapshots until the visible scopes change" do
    previous_adapter = FactoryHoist.configuration.factory_adapter
    FactoryHoist.configuration.factory_adapter = lambda do |_strategy, name, _traits, _attributes|
      {factory: name}
    end
    outer = Object.new
    inner = Object.new
    outer_definition = FactoryHoist::Definition.new(:value, :outer, [], {}, nil, "outer")
    inner_definition = FactoryHoist::Definition.new(:value, :inner, [], {}, nil, "inner")
    session = described_class.new
    allow(FactoryHoist::ValueCopying).to receive(:snapshot).and_call_original

    session.enter(outer, {value: outer_definition})
    2.times { session.fetch(Object.new, :value, nil, value: outer_definition) }
    session.enter(inner, {value: inner_definition})
    nested = session.fetch(Object.new, :value, nil, value: inner_definition)
    session.leave(inner)
    restored = session.fetch(Object.new, :value, nil, value: outer_definition)

    expect(nested).to eq(factory: :inner)
    expect(restored).to eq(factory: :outer)
    expect(FactoryHoist::ValueCopying).to have_received(:snapshot).exactly(3).times
  ensure
    session&.close
    FactoryHoist.configuration.factory_adapter = previous_adapter
  end
end

RSpec.describe "FactoryHoist with ActiveRecord" do
  before(:context) do
    FactoryHoist.stats.reset!
    FactoryHoist.configuration.factory_adapter = nil
    FactoryHoist.configuration.subxid_budget = 60
  end

  hoist(:user, :factory_hoist_user)

  it "makes the hoisted row visible before the example" do
    expect(FactoryHoistUser.count).to eq(1)
    expect(user).to be_persisted
  end

  it "allows updates inside an example savepoint" do
    user.update!(name: "changed")

    expect(user.reload.name).to eq("changed")
  end

  it "rolls database changes back between examples" do
    expect(user.reload.name).to eq("original")
  end
end

RSpec.describe "FactoryHoist ActiveRecord cleanup" do
  it "rolls hoisted rows back after the group exits" do
    expect(FactoryHoistUser.count).to eq(0)
  end
end

RSpec.describe "FactoryHoist context hook isolation" do
  before(:context) do
    FactoryHoist.configuration.factory_adapter = nil
    FactoryHoist.configuration.subxid_budget = 1
  end
  before(:context) { FactoryHoistUser.create!(name: "context setup") }
  after(:context) { expect(FactoryHoistUser.count).to eq(2) }

  hoist(:user, :factory_hoist_user)

  it "wraps existing context hooks in the group transaction" do
    expect(user.name).to eq("original")
    expect(FactoryHoistUser.count).to eq(2)
  end

  it "preserves context hook writes across transaction rebuilds" do
    expect(user.name).to eq("original")
    expect(FactoryHoistUser.count).to eq(2)
  end
end

RSpec.describe "FactoryHoist nested context hook rebuild safety" do
  before(:context) do
    FactoryHoist.configuration.factory_adapter = nil
    FactoryHoist.configuration.subxid_budget = 1
  end

  hoist(:user, :factory_hoist_user)

  it "uses the parent hoist before entering the nested context" do
    expect(user.name).to eq("original")
    expect(FactoryHoistUser.count).to eq(1)
  end

  context "with database setup but no scheduled child scope" do
    before(:context) { FactoryHoistUser.create!(name: "nested context setup") }
    after(:context) { expect(FactoryHoistUser.count).to eq(2) }

    it "does not discard the nested context setup when the budget is reached" do
      expect(user.name).to eq("original")
      expect(FactoryHoistUser.count).to eq(2)
    end
  end
end

RSpec.describe "FactoryHoist context hook cleanup" do
  it "rolls context hook writes back with hoisted rows" do
    expect(FactoryHoistUser.count).to eq(0)
  end
end

RSpec.describe "FactoryHoist subtransaction budget" do
  before(:context) do
    FactoryHoist.stats.reset!
    FactoryHoist.configuration.factory_adapter = nil
    FactoryHoist.configuration.subxid_budget = 1
  end

  hoist(:user, :factory_hoist_user)

  it "rebuilds hoisted data after the configured number of examples" do
    expect(user.name).to eq("original")
    expect(FactoryHoist.stats.to_h[:materializations]).to eq(1)

    nested_example = Object.new
    nested_example.define_singleton_method(:run) { FactoryHoistUser.count }
    FactoryHoist::Runtime.current.around_example(nested_example)

    expect(FactoryHoist.stats.to_h).to include(
      materializations: 2,
      transaction_rebuilds: 1
    )
  end
end

RSpec.describe "FactoryHoist bulk insertion" do
  before { FactoryHoistUser.delete_all }
  after { FactoryHoistUser.delete_all }

  it "uses ActiveRecord insert_all for explicit unsafe writes" do
    FactoryHoist.unsafe_bulk_insert(:factory_hoist_user, 2, name: "bulk")

    expect(FactoryHoistUser.pluck(:name)).to eq(%w[bulk bulk])
  end


  it "identifies the failing row without leaving partial inserts" do
    FactoryHoistUser.transaction do
      expect { FactoryHoist.unsafe_bulk_insert(:factory_hoist_user, 2, name: nil) }
        .to raise_error(FactoryHoist::BulkInsertionError, /row 0/)
      FactoryHoistUser.create!(name: "transaction remains usable")
    end

    expect(FactoryHoistUser.pluck(:name)).to eq(["transaction remains usable"])
  end

  it "keeps the original failure when row diagnosis is unavailable" do
    unavailable = Class.new do
      def self.transaction(...)
        raise "diagnosis unavailable"
      end
    end

    expect(FactoryHoist::BulkInsertion.send(:failing_row, unavailable, [{}])).to be_nil
  end
end

RSpec.describe FactoryHoist::DatabaseStateDigest do
  it "changes when a hoisted database row changes" do
    user = FactoryHoistUser.create!(name: "before")
    other = FactoryHoistUser.create!(name: "other")
    scope = Struct.new(:values).new({user: user, other: other})
    before = described_class.call([scope])

    other.update!(name: "after")

    expect(described_class.call([scope])).not_to eq(before)
  ensure
    FactoryHoistUser.where(id: [user&.id, other&.id]).delete_all
  end

  it "makes paranoid sessions reject database mutations" do
    FactoryHoist.reset!
    FactoryHoist.configuration.paranoid_mode = true
    session = FactoryHoist::Runtime::Session.new
    group = Object.new
    definition = FactoryHoist::Definition.new(
      :user, :factory_hoist_user, [], {}, nil, "paranoid test"
    )
    session.enter(group, {user: definition})
    example = Object.new
    example.define_singleton_method(:run) { FactoryHoistUser.first.update!(name: "changed") }

    expect { session.around_example(example) }
      .to raise_error(FactoryHoist::SharedDataMutationError)
  ensure
    session&.leave(group) if group
    FactoryHoist.configuration.paranoid_mode = false
  end

  it "snapshots named and anonymous ActiveRecord models together" do
    anonymous = Class.new(ActiveRecord::Base) do
      self.table_name = "factory_hoist_users"
    end
    named_record = FactoryHoistUser.create!(name: "named")
    anonymous_record = anonymous.create!(name: "anonymous")
    scope = Struct.new(:values).new({named: named_record, anonymous: anonymous_record})

    expect(described_class.call([scope])).to match(/\A[0-9a-f]{64}\z/)
  ensure
    FactoryHoistUser.where(id: [named_record&.id, anonymous_record&.id]).delete_all
  end

  it "snapshots composite primary keys" do
    membership = FactoryHoistMembership.create!(account_id: 1, user_id: 2, role: "owner")
    scope = Struct.new(:values).new({membership: membership})
    before = described_class.call([scope])

    membership.update!(role: "member")

    expect(described_class.call([scope])).not_to eq(before)
  ensure
    FactoryHoistMembership.delete_all
  end

  it "snapshots the selected row when a model has no primary key" do
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "factory_hoist_memberships"
      self.primary_key = nil
    end
    model.create!(account_id: 1, user_id: 1, role: "unrelated")
    membership = model.create!(account_id: 2, user_id: 2, role: "owner")
    scope = Struct.new(:values).new({membership: membership})
    before = described_class.call([scope])

    model.where(account_id: 2, user_id: 2).update_all(role: "member")

    expect(described_class.call([scope])).not_to eq(before)
  ensure
    model&.delete_all
  end
end

RSpec.describe "FactoryHoist materialization failure cleanup" do
  it "rolls back partial group materialization immediately" do
    FactoryHoist.configuration.factory_adapter = lambda do |_strategy, name, _traits, _attributes|
      raise "failed factory" if name == :bad

      FactoryHoistUser.create!(name: "partial")
    end
    definitions = {
      good: FactoryHoist::Definition.new(:good, :good, [], {}, nil, "cleanup"),
      bad: FactoryHoist::Definition.new(:bad, :bad, [], {}, nil, "cleanup")
    }
    session = FactoryHoist::Runtime::Session.new
    group = Object.new
    session.enter(group, definitions, materialize: false)

    expect { session.materialize(group) }.to raise_error(FactoryHoist::MaterializationError)
    expect(FactoryHoistUser.count).to eq(0)
  ensure
    session&.leave(group) if group
  end
end

RSpec.describe "FactoryHoist late connection cleanup" do
  it "starts the group transaction when the connection becomes available" do
    FactoryHoist.configuration.factory_adapter = nil
    session = FactoryHoist::Runtime::Session.new
    transaction = session.instance_variable_get(:@transaction)
    connection = ActiveRecord::Base.connection
    allow(transaction).to receive(:active_record_connection).and_return(nil, nil, connection)
    definition = FactoryHoist::Definition.new(
      :user, :factory_hoist_user, [], {}, nil, "late connection"
    )
    group = Object.new
    session.enter(group, {user: definition}, materialize: false)
    session.materialize(group)

    expect(FactoryHoistUser.count).to eq(1)
    session.leave(group)
    group = nil
    expect(FactoryHoistUser.count).to eq(0)
  ensure
    session&.leave(group) if group
    FactoryHoistUser.delete_all
  end
end

RSpec.describe "FactoryHoist reset cleanup" do
  it "rolls back an active runtime before replacing it" do
    FactoryHoist.reset!
    FactoryHoist.configuration.factory_adapter = nil
    definition = FactoryHoist::Definition.new(
      :user, :factory_hoist_user, [], {}, nil, "reset cleanup"
    )
    FactoryHoist::Runtime.current.enter(Object.new, {user: definition})

    expect(FactoryHoistUser.count).to eq(1)
    FactoryHoist.reset!

    expect(FactoryHoistUser.count).to eq(0)
    expect(ActiveRecord::Base.connection).not_to be_transaction_open
  ensure
    ActiveRecord::Base.connection.rollback_transaction if ActiveRecord::Base.connection.transaction_open?
    FactoryHoistUser.delete_all
    FactoryHoist.reset!
  end
end

RSpec.describe "FactoryHoist ActiveRecord local fallback" do
  before(:context) { FactoryHoist.configuration.factory_adapter = nil }
  let(:local_name) { "example local" }
  hoist(:local_user, :factory_hoist_user) { {name: local_name} }

  2.times do
    it "rolls a dynamically local record back after the example" do
      expect(FactoryHoistUser.count).to eq(0)
      expect(local_user.name).to eq("example local")
      expect(FactoryHoistUser.count).to eq(1)
    end
  end
end

RSpec.describe "FactoryHoist ActiveRecord local fallback cleanup" do
  it "does not leak local records after the group" do
    expect(FactoryHoistUser.count).to eq(0)
  end
end
