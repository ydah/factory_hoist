# frozen_string_literal: true

module FactoryHoist
  class Stats
    COUNTERS = %i[deoptimizations materializations references transaction_rebuilds].freeze

    def initialize
      @mutex = Mutex.new
      reset!
    end

    def increment(counter, amount = 1)
      raise ArgumentError, "unknown counter: #{counter}" unless COUNTERS.include?(counter)

      @mutex.synchronize { @counters[counter] += amount }
    end

    def record_cost(key, seconds)
      @mutex.synchronize { @costs[key.to_s] += seconds }
    end

    def to_h
      @mutex.synchronize do
        @counters.merge(
          degradation_rate: degradation_rate,
          materialization_costs: @costs.sort_by { |_, seconds| -seconds }.to_h
        )
      end
    end

    def reset!
      @mutex.synchronize do
        @counters = COUNTERS.to_h { |counter| [counter, 0] }
        @costs = Hash.new(0.0)
      end
    end

    private

    def degradation_rate
      return 0.0 if @counters[:references].zero?

      @counters[:deoptimizations].fdiv(@counters[:references])
    end
  end
end
