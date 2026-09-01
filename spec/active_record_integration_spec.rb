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
  before(:context) { FactoryHoist.reset! }

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

RSpec.describe "FactoryHoist subtransaction budget" do
  before(:context) do
    FactoryHoist.reset!
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
end
