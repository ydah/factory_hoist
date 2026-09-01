# FactoryHoist

FactoryHoist creates FactoryBot records once at an RSpec example-group boundary, then gives every example an isolated in-memory copy. ActiveRecord changes are isolated with savepoints and rolled back when the group exits.

## Installation

Add the gem to the test group:

```ruby
group :test do
  gem "factory_hoist"
end
```

## Usage

`hoist` uses the declaration's name as the FactoryBot factory by default. A block returns attribute overrides and can refer to ancestor declarations.

```ruby
RSpec.describe Order do
  hoist(:company)
  hoist(:user) { {company: company} }

  context "paid" do
    hoist(:order) { {user: user, state: :paid} }

    it "can update its isolated copy" do
      order.update!(state: :cancelled)
    end

    it "preserves relationships" do
      expect(order.user).to equal(user)
    end
  end
end
```

Traits and an alternate factory name are supported:

```ruby
hoist(:admin, :user, :admin, active: true)
```

The direct APIs delegate to FactoryBot:

```ruby
FactoryHoist.build(:user)
FactoryHoist.create(:user)
FactoryHoist.build_list(:user, 3)
FactoryHoist.create_list(:user, 3)
```

Bulk insertion is explicitly unsafe because it skips validations and callbacks:

```ruby
FactoryHoist.unsafe_bulk_insert(:user, 10_000)
```

It uses FactoryBot's `attributes_for` and ActiveRecord's `insert_all!`; it is intended for performance and seed data only.

### Configuration

```ruby
FactoryHoist.configure do |config|
  config.subxid_budget = 60
  config.suite_seed = ENV.fetch("FACTORY_HOIST_SEED", 0).to_i
  config.paranoid_mode = false
end
```

`subxid_budget` rebuilds an owned outer transaction after that many examples. Set it to `0` to disable rebuilding. `suite_seed` makes `FactoryHoist.random` deterministic for a declaration path and key. `paranoid_mode` checks hoisted ActiveRecord rows before and after every example and raises if they changed.

### Advice and statistics

```console
$ bundle exec factory_hoist advise spec/
```

The command reports repeated literal factory calls and declarations that appear unused. Runtime counters and materialization costs are available through `FactoryHoist.stats.to_h`.

## Constraints

- RSpec is supported. Minitest group lifecycle support is not implemented.
- `after_commit` does not fire inside the managed transaction.
- Objects that `Marshal` cannot copy silently use example-local creation and increment the degradation counter.
- DatabaseCleaner truncation is incompatible and emits a warning; use its transaction strategy.
- System specs need a shared database connection. Multi-database applications are not supported.
- Raw SQL and `update_all` are rolled back between examples, but can still create ordering effects inside one example.

## Development

Run `bundle install`, then `bundle exec rake`. The suite includes an in-memory SQLite integration test for transaction and savepoint behavior.

## Contributing

Bug reports and pull requests are welcome.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
