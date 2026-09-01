# frozen_string_literal: true

require "factory_bot"
require "monitor"
require_relative "factory_hoist/configuration"
require_relative "factory_hoist/pcg32"
require_relative "factory_hoist/runtime"
require_relative "factory_hoist/stats"
require_relative "factory_hoist/version"

module FactoryHoist
  RANDOM_MONITOR = Monitor.new

  class Error < StandardError; end
  class BulkWriteError < Error; end
  class DuplicateHoistError < Error; end
  class FactoryUnavailableError < Error; end
  class MaterializationError < Error; end
  class SharedDataMutationError < Error; end

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset!
      @configuration = Configuration.new
      Thread.current[:factory_hoist_random] = nil
      stats.reset!
      Runtime.reset!
      FastBuild.reset! if defined?(FastBuild)
    end

    def build(name, *traits, **attributes)
      return build_factory(name, traits, attributes) unless defined?(::Faker::Config)

      with_random_source(random) { build_factory(name, traits, attributes) }
    end

    def create(name, *traits, **attributes)
      run_factory(:create, name, traits, attributes)
    end

    def build_list(name, count, *traits, **attributes)
      Array.new(count) { build(name, *traits, **attributes) }
    end

    def create_list(name, count, *traits, **attributes)
      Array.new(count) { create(name, *traits, **attributes) }
    end

    def unsafe_bulk_insert(name, count, *traits, **attributes)
      require_relative "factory_hoist/bulk_writer"
      BulkWriter.call(name, count, traits, attributes)
    end

    def clone_database(source:, target:, adapter:)
      require_relative "factory_hoist/parallel_database"
      ParallelDatabase.clone(source: source, target: target, adapter: adapter)
    end

    def advise(*paths, io: $stdout)
      require_relative "factory_hoist/advisor"
      Advisor.new(paths.empty? ? ["spec"] : paths).print(io)
    end

    def stats
      @stats ||= Stats.new
    end

    def random
      Thread.current[:factory_hoist_random] ||= PCG32.new(configuration.suite_seed)
    end

    def with_seed(seed)
      with_random_source(PCG32.new(seed)) { yield }
    end

    private

    def build_factory(name, traits, attributes)
      adapter = configuration.factory_adapter
      return adapter.call(:build, name, traits, attributes) if adapter

      require_relative "factory_hoist/fast_build"
      result = FastBuild.call(name, traits, attributes)
      return result unless result.equal?(FastBuild::FALLBACK)

      call_factory_bot(:build, name, traits, attributes)
    end

    def with_random_source(source)
      faker_config = ::Faker::Config if defined?(::Faker::Config)
      if RANDOM_MONITOR.mon_owned? && Thread.current[:factory_hoist_random].equal?(source) &&
          (!faker_config || faker_config.random.equal?(source))
        return yield
      end
      return scope_random_source(source) { yield } unless faker_config

      RANDOM_MONITOR.synchronize { scope_random_source(source) { yield } }
    end

    def scope_random_source(source)
      previous = Thread.current[:factory_hoist_random]
      Thread.current[:factory_hoist_random] = source
      faker_config = ::Faker::Config if defined?(::Faker::Config)
      previous_faker = faker_config.random if faker_config
      faker_config.random = source if faker_config
      yield
    ensure
      faker_config.random = previous_faker if faker_config
      Thread.current[:factory_hoist_random] = previous
    end

    def run_factory(strategy, name, traits, attributes)
      adapter = configuration.factory_adapter
      adapter ||= default_factory_adapter
      adapter.call(strategy, name, traits, attributes)
    end

    def default_factory_adapter
      return method(:call_factory_bot) if defined?(::FactoryBot)

      raise FactoryUnavailableError,
        "configure FactoryHoist.configuration.factory_adapter or require factory_bot"
    end

    def call_factory_bot(strategy, name, traits, attributes)
      ::FactoryBot.public_send(strategy, name, *traits, **attributes)
    end
  end
end

require_relative "factory_hoist/rspec" if defined?(::RSpec)
require_relative "factory_hoist/minitest" if defined?(::Minitest::Test)
