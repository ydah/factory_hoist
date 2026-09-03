# frozen_string_literal: true

require "openssl"
require_relative "database_state_digest"
require_relative "definition"
require_relative "value_copying"

module FactoryHoist
  module Runtime
    THREAD_KEY = :factory_hoist_runtime

    module_function

    def current
      Thread.current[THREAD_KEY] ||= Session.new
    end

    def reset!
      Thread.current[THREAD_KEY]&.close
    ensure
      Thread.current[THREAD_KEY] = nil
    end

    def seed(node_path, key, index = 0)
      input = [FactoryHoist.configuration.suite_seed, node_path, key, index].join("\0")
      OpenSSL::Digest.digest("BLAKE2b512", input).unpack1("Q>")
    end
  end
end

require_relative "runtime/example_materialization_context"
require_relative "runtime/example_value_store"
require_relative "runtime/materialization_context"
require_relative "runtime/scope"
require_relative "runtime/transaction"
require_relative "runtime/session"
