# frozen_string_literal: true

require "active_record"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.define do
  create_table :factory_hoist_users, force: true do |table|
    table.string :name, null: false
  end
end

class FactoryHoistUser < ActiveRecord::Base
end

FactoryBot.define do
  factory :factory_hoist_user do
    name { "original" }
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
  before(:context) { FactoryHoistUser.create!(name: "context setup") }

  hoist(:user, :factory_hoist_user)

  it "wraps existing context hooks in the group transaction" do
    expect(user.name).to eq("original")
    expect(FactoryHoistUser.count).to eq(2)
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

  it "starts with one materialization" do
    expect(user.name).to eq("original")
    expect(FactoryHoist.stats.to_h[:materializations]).to eq(1)
  end

  it "rebuilds hoisted data after the configured number of examples" do
    expect(user.name).to eq("original")
    expect(FactoryHoist.stats.to_h).to include(
      materializations: 2,
      transaction_rebuilds: 1
    )
  end
end

RSpec.describe "FactoryHoist bulk writer" do
  before { FactoryHoistUser.delete_all }
  after { FactoryHoistUser.delete_all }

  it "uses ActiveRecord insert_all for explicit unsafe writes" do
    FactoryHoist.unsafe_bulk_insert(:factory_hoist_user, 2, name: "bulk")

    expect(FactoryHoistUser.pluck(:name)).to eq(%w[bulk bulk])
  end


  it "identifies the failing row without leaving partial inserts" do
    expect { FactoryHoist.unsafe_bulk_insert(:factory_hoist_user, 2, name: nil) }
      .to raise_error(FactoryHoist::BulkWriteError, /row 0/)
    expect(FactoryHoistUser.count).to eq(0)
  end
end

RSpec.describe FactoryHoist::DatabaseSnapshot do
  it "changes when a hoisted database row changes" do
    user = FactoryHoistUser.create!(name: "before")
    scope = Struct.new(:values).new({user: user})
    before = described_class.call([scope])

    user.update!(name: "after")

    expect(described_class.call([scope])).not_to eq(before)
  ensure
    user&.destroy!
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
end
