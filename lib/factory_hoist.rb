# frozen_string_literal: true

require "factory_bot"
require "minitest"
require "monitor"
require "rspec/core"
require_relative "factory_hoist/error"
require_relative "factory_hoist/bulk_insertion_error"
require_relative "factory_hoist/configuration"
require_relative "factory_hoist/duplicate_hoist_error"
require_relative "factory_hoist/factory_unavailable_error"
require_relative "factory_hoist/materialization_error"
require_relative "factory_hoist/pcg32"
require_relative "factory_hoist/runtime"
require_relative "factory_hoist/shared_data_mutation_error"
require_relative "factory_hoist/statistics"
require_relative "factory_hoist/version"

module FactoryHoist
  RANDOM_MONITOR = Monitor.new

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
      CompiledFactoryBuilder.reset! if defined?(CompiledFactoryBuilder)
    end

    def build(name, *traits, **attributes, &block)
      result = if defined?(::Faker::Config)
        with_random_source(random) { build_factory(name, traits, attributes) }
      else
        build_factory(name, traits, attributes)
      end

      result.tap { |record| block&.call(record) }
    end

    def create(name, *traits, **attributes, &block)
      run_factory(:create, name, traits, attributes).tap { |record| block&.call(record) }
    end

    def build_list(name, count, *traits, **attributes, &block)
      Array.new(count) do |index|
        build(name, *traits, **attributes).tap { |record| block&.call(record, index) }
      end
    end

    def create_list(name, count, *traits, **attributes, &block)
      Array.new(count) do |index|
        create(name, *traits, **attributes).tap { |record| block&.call(record, index) }
      end
    end

    def unsafe_bulk_insert(name, count, *traits, **attributes)
      require_relative "factory_hoist/bulk_insertion"
      BulkInsertion.call(name, count, traits, attributes)
    end

    def clone_database(source:, target:, adapter:)
      require_relative "factory_hoist/database_cloning"
      DatabaseCloning.clone(source: source, target: target, adapter: adapter)
    end

    def advise(*paths, io: $stdout)
      require_relative "factory_hoist/advisor"
      Advisor.new(paths.empty? ? ["spec"] : paths).print(io)
    end

    def stats
      @stats ||= Statistics.new
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

      require_relative "factory_hoist/compiled_factory_builder" unless defined?(::FactoryHoist::CompiledFactoryBuilder)
      result = CompiledFactoryBuilder.call(name, traits, attributes)
      return result unless result.equal?(CompiledFactoryBuilder::FALLBACK)

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

require_relative "factory_hoist/rspec"
require_relative "factory_hoist/minitest"
