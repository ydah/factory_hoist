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
      return rand * limit if limit.is_a?(Numeric) && limit.positive?

      raise ArgumentError, "unsupported random limit: #{limit.inspect}"
    end

    def bytes(length)
      Array.new(length) { rand(256) }.pack("C*")
    end

    private

    def integer(limit)
      raise ArgumentError, "random limit must be positive: #{limit}" unless limit.positive?
      return 0 if limit == 1

      bits = (limit - 1).bit_length
      words = (bits + 31) / 32
      mask = (1 << bits) - 1
      loop do
        value = 0
        words.times { value = (value << 32) | next_uint32 }
        value &= mask
        return value if value < limit
      end
    end

    def range(value)
      first = value.begin
      last = value.end
      if first.is_a?(Integer) && last.is_a?(Integer)
        size = last - first + (value.exclude_end? ? 0 : 1)
        return first + integer(size)
      end
      if defined?(::Date) && first.instance_of?(::Date) && last.instance_of?(::Date)
        size = (last - first).to_i + (value.exclude_end? ? 0 : 1)
        return first + integer(size)
      end
      return first if first == last && !value.exclude_end?

      size = last - first
      raise ArgumentError, "non-numeric range distance: #{value.inspect}" unless size.is_a?(Numeric)
      raise ArgumentError, "empty random range: #{value.inspect}" unless size.positive?

      first + (rand * size)
    rescue NoMethodError
      raise ArgumentError, "unsupported random range: #{value.inspect}"
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
