<h1 align="center">FactoryHoist</h1>

<p align="center">
  <strong>Share FactoryBot data safely across RSpec examples</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/factory_hoist"><img src="https://img.shields.io/gem/v/factory_hoist.svg?colorB=319e8c" alt="Gem Version"></a>
  <a href="https://rubygems.org/gems/factory_hoist"><img src="https://img.shields.io/gem/dt/factory_hoist.svg" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/ruby-%3E%3D%203.2-ruby.svg" alt="Ruby Version">
  <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License">
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#how-it-works">How It Works</a>
</p>

---

FactoryHoist creates FactoryBot records once at the smallest shared RSpec example-group boundary, then gives every example an isolated in-memory copy. ActiveRecord changes are isolated with savepoints and rolled back when the group exits.

## Features

- Hoists referenced FactoryBot records to the nearest shared RSpec group
- Preserves object relationships while returning an isolated copy to each example
- Rolls back example and group changes with ActiveRecord savepoints
- Falls back to example-local creation for dynamic or unsupported declarations
- Seeds factory and Faker values deterministically for hoisted declarations
- Accelerates simple callback-free FactoryBot builds
- Reports hoist candidates, unused declarations, degradation, and materialization cost
- Clones PostgreSQL and SQLite databases safely for parallel workers

## Installation

Add FactoryHoist to the test group in your Gemfile:

```ruby
group :test do
  gem "factory_hoist"
end
```

Then install:

```bash
bundle install
```

### Requirements

- Ruby 3.2+
- FactoryBot 6.5+
- ActiveRecord 7.1+ for database-backed features
- RSpec 3.12+ or Minitest 5+

## Quick Start

Load FactoryHoist from your test helper:

```ruby
require "factory_hoist"
```

Declare shared factories with `hoist`:

```ruby
RSpec.describe Order do
  hoist(:company)
  hoist(:user) { {company: company} }

  context "paid" do
    hoist(:order) { {user: user, state: :paid} }

    it "can update its isolated copy" do
      order.update!(state: :cancelled)
      expect(order.state).to eq("cancelled")
    end

    it "preserves relationships" do
      expect(order.user).to equal(user)
    end
  end
end
```

The declaration name is used as the FactoryBot factory name by default. FactoryHoist creates each hoisted record once, rolls example changes back, and lazily copies the visible object graph for each example.

## Usage

### Traits, factories, and attributes

Pass an alternate factory name, traits, and attributes after the declaration name:

```ruby
hoist(:admin, :user, :admin, active: true)
```

A declaration block returns dynamic attributes and can reference ancestor declarations:

```ruby
hoist(:account)
hoist(:owner) { {account: account} }
```

### Direct factory APIs

FactoryHoist mirrors FactoryBot's direct APIs and preserves their block behavior:

```ruby
FactoryHoist.build(:user)
FactoryHoist.create(:user)
FactoryHoist.build_list(:user, 3)
FactoryHoist.create_list(:user, 3)
```

### Fast Build

Simple callback-free builds are compiled to a Ruby file under the system temporary directory and bypass FactoryBot's evaluation pipeline. Traits, callbacks, required constructors, and unsupported definitions automatically fall back to FactoryBot.

Run the fixed-condition benchmark with:

```bash
bundle exec ruby bench/fast_build.rb
```

### Bulk insertion

`unsafe_bulk_insert` uses FactoryBot's `attributes_for` and ActiveRecord's `insert_all!`:

```ruby
FactoryHoist.unsafe_bulk_insert(:user, 10_000)
```

It intentionally skips validations and callbacks, so use it only for performance tests and seed data.

### Advice and statistics

Run the selected RSpec suite and report repeated literal factory calls, unused hoists, degradation, and the most expensive materializations:

```bash
bundle exec factory_hoist advise spec/
```

Runtime counters are also available through `FactoryHoist.stats.to_h`.

### Parallel databases

Clone a disconnected PostgreSQL template under an advisory lock, or a SQLite database through SQLite's online backup API:

```ruby
FactoryHoist.clone_database(
  source: "postgresql:///app_test_template",
  target: "app_test_1",
  adapter: :postgresql
)
```

## Configuration

Configure FactoryHoist in your test helper:

```ruby
FactoryHoist.configure do |config|
  config.subxid_budget = 60
  config.suite_seed = ENV.fetch("FACTORY_HOIST_SEED", 0).to_i
  config.paranoid_mode = false
end
```

| Option | Type | Default | Description |
|---|---|---:|---|
| `factory_adapter` | Callable | `nil` | Override FactoryBot for custom factory backends |
| `paranoid_mode` | Boolean | `false` | Reject changes to hoisted ActiveRecord rows inside an example |
| `subxid_budget` | Integer | `60` | Rebuild an owned outer transaction after this many examples |
| `suite_seed` | Integer | `0` | Seed deterministic declaration and Faker values |

Set `subxid_budget` to `0` to disable rebuilding. Rebuilding is deferred while an active `before(:context)` hook has written database state that FactoryHoist cannot rematerialize; move that setup into `hoist` when the budget must remain strict.

## How It Works

1. Scheduler Analysis inspects selected RSpec examples and finds referenced declarations
2. LCA Placement schedules each declaration at the nearest shared example-group boundary
3. Group Materialization creates the records inside an outer transaction and group savepoint
4. Example Isolation opens a savepoint and lazily copies the visible object graph for each example
5. Rollback discards example changes immediately and group data when the group exits
6. Safe Degradation creates values locally when static scheduling or copying is unsafe

## Constraints

- Minitest accepts the same DSL but creates values once per test because it has no portable example-group lifecycle.
- Declarations that use example-local helpers, instance variables, `initialize_with`, or `to_create` are created inside the example transaction instead of being shared.
- `after_commit` does not fire inside the managed transaction.
- Objects that `Marshal` cannot copy use example-local creation and increment the degradation counter.
- DatabaseCleaner truncation is incompatible and emits a warning; use its transaction strategy.
- System specs need a shared database connection. Multi-database applications are not supported.
- Raw SQL and `update_all` are rolled back between examples but can still create ordering effects inside one example.

## Development

Install dependencies and run the test suite:

```bash
bundle install
bundle exec rake
```

Run the performance gates:

```bash
bundle exec ruby bench/fast_build.rb
bundle exec ruby bench/phase0_synthetic.rb
```

With a local PostgreSQL server available, verify the subtransaction budget, database statistics, failure recovery, and clone paths:

```bash
DATABASE_URL=postgresql:///postgres bundle exec ruby script/verify_postgresql
bundle exec ruby script/verify_postgresql_clone
```

The design-to-implementation review is recorded in [docs/adversarial-audit.md](docs/adversarial-audit.md), and the reproducible synthetic benchmark is recorded in [docs/phase0-synthetic.md](docs/phase0-synthetic.md).

## Contributing

Bug reports and pull requests are welcome at https://github.com/ydah/factory_hoist.

## License

Released under the [MIT License](LICENSE.txt).
