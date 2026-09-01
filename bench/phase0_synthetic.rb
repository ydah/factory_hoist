# frozen_string_literal: true

require "bundler/setup"
require "active_record"
require "factory_hoist"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:phase0_companies) { |table| table.string :name, null: false }
  create_table(:phase0_orders) do |table|
    table.references :company, null: false
    table.string :state, null: false
  end
end

class Phase0Company < ActiveRecord::Base
end

class Phase0Order < ActiveRecord::Base
  belongs_to :company, class_name: "Phase0Company"
end

FactoryBot.define do
  factory :phase0_company do
    name { "Acme" }
  end
  factory :phase0_order do
    association :company, factory: :phase0_company
    state { "paid" }
  end
end

examples = Integer(ENV.fetch("N", 200))
connection = ActiveRecord::Base.connection
measure = lambda do |&block|
  inserts = 0
  subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
    inserts += 1 if payload[:sql].match?(/\AINSERT/i)
  end
  times = 3.times.map do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    block.call
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end
  [times.sort[1], inserts / 3]
ensure
  ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
end

baseline = measure.call do
  examples.times do
    connection.transaction(requires_new: true) do
      FactoryBot.create(:phase0_order)
      raise ActiveRecord::Rollback
    end
  end
end

let_it_be = measure.call do
  connection.transaction(requires_new: true) do
    shared = FactoryBot.create(:phase0_order)
    examples.times do
      connection.transaction(requires_new: true) do
        Marshal.load(Marshal.dump(shared))
        raise ActiveRecord::Rollback
      end
    end
    raise ActiveRecord::Rollback
  end
end

factory_hoist = measure.call do
  FactoryHoist.configuration.factory_adapter = nil
  FactoryHoist.configuration.subxid_budget = examples + 1
  definition = FactoryHoist::Definition.new(:order, :phase0_order, [], {}, nil, "phase0")
  session = FactoryHoist::Runtime::Session.new
  group = Object.new
  session.enter(group, {order: definition})
  examples.times do
    example = Object.new
    example.define_singleton_method(:run) do
      session.fetch(self, :order, definition, {order: definition})
    end
    session.around_example(example)
  end
  session.leave(group)
end

reduction = 1 - factory_hoist[1].fdiv(baseline[1])
report = <<~REPORT
  # Synthetic Phase 0 report

  | Path | Median | INSERTs |
  |---|---:|---:|
  | FactoryBot | #{format("%.4fs", baseline[0])} | #{baseline[1]} |
  | let_it_be equivalent | #{format("%.4fs", let_it_be[0])} | #{let_it_be[1]} |
  | factory_hoist | #{format("%.4fs", factory_hoist[0])} | #{factory_hoist[1]} |

  Record reduction: #{format("%.1f%%", reduction * 100)}
  Dynamic-argument rate: 0.0% (synthetic fixture)
  Tree depth: 1; writing examples per file: #{examples}
  Stop decision: undetermined without the target suite and its target time.
REPORT

puts report
File.write(ENV["REPORT"], report) if ENV["REPORT"]
raise "synthetic record reduction missed 60%" if reduction < 0.6
