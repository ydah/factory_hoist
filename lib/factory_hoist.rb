# frozen_string_literal: true

require "factory_bot"
require_relative "factory_hoist/configuration"
require_relative "factory_hoist/runtime"
require_relative "factory_hoist/stats"
require_relative "factory_hoist/version"

module FactoryHoist
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
      stats.reset!
      Runtime.reset!
      FastBuild.reset! if defined?(FastBuild)
    end

    def build(name, *traits, **attributes)
      adapter = configuration.factory_adapter
      return adapter.call(:build, name, traits, attributes) if adapter

      require_relative "factory_hoist/fast_build"
      result = FastBuild.call(name, traits, attributes)
      return result unless result.equal?(FastBuild::FALLBACK)

      call_factory_bot(:build, name, traits, attributes)
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

    def advise(*paths, io: $stdout)
      require_relative "factory_hoist/advisor"
      Advisor.new(paths.empty? ? ["spec"] : paths).print(io)
    end

    def stats
      @stats ||= Stats.new
    end

    def random
      Thread.current[:factory_hoist_random] ||= Random.new(configuration.suite_seed)
    end

    def with_seed(seed)
      previous = Thread.current[:factory_hoist_random]
      Thread.current[:factory_hoist_random] = Random.new(seed)
      faker_config = ::Faker::Config if defined?(::Faker::Config)
      previous_faker = faker_config.random if faker_config
      faker_config.random = Thread.current[:factory_hoist_random] if faker_config
      yield
    ensure
      faker_config.random = previous_faker if faker_config
      Thread.current[:factory_hoist_random] = previous
    end

    private

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
