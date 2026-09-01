# frozen_string_literal: true

module FactoryHoist
  class PCG32
    MULTIPLIER = 6_364_136_223_846_793_005
    MASK_64 = (1 << 64) - 1

    def initialize(seed, stream = 1)
      @state = 0
      @increment = ((stream << 1) | 1) & MASK_64
      next_uint32
      @state = (@state + seed) & MASK_64
      next_uint32
    end

    def rand(limit = nil)
      return next_uint32.fdiv(1 << 32) unless limit
      return integer(limit) if limit.is_a?(Integer)
      return range(limit) if limit.is_a?(Range)

      raise ArgumentError, "unsupported random limit: #{limit.inspect}"
    end

    def bytes(length)
      Array.new(length) { rand(256) }.pack("C*")
    end

    private

    def integer(limit)
      unless limit.positive? && limit <= (1 << 32)
        raise ArgumentError, "random limit must be between 1 and 2^32: #{limit}"
      end

      threshold = ((1 << 32) - limit) % limit
      loop do
        value = next_uint32
        return value % limit if value >= threshold
      end
    end

    def range(value)
      first = value.begin
      last = value.end
      raise ArgumentError, "non-integer ranges are unsupported" unless first.is_a?(Integer) && last.is_a?(Integer)

      size = last - first + (value.exclude_end? ? 0 : 1)
      first + integer(size)
    end

    def next_uint32
      old_state = @state
      @state = (old_state * MULTIPLIER + @increment) & MASK_64
      xor_shifted = (((old_state >> 18) ^ old_state) >> 27) & 0xffffffff
      rotation = old_state >> 59
      ((xor_shifted >> rotation) | (xor_shifted << ((-rotation) & 31))) & 0xffffffff
    end
  end
end
