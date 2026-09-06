# frozen_string_literal: true

module FactoryHoist
  class Configuration
    attr_accessor :factory_adapter, :subxid_budget, :suite_seed
    attr_writer :paranoid_mode

    def initialize
      @factory_adapter = nil
      @paranoid_mode = false
      @subxid_budget = 60
      @suite_seed = 0
    end

    def paranoid_mode?
      @paranoid_mode
    end
  end
end
