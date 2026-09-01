# frozen_string_literal: true

module FactoryHoist
  class Configuration
    attr_accessor :factory_adapter, :paranoid_mode, :subxid_budget, :suite_seed

    def initialize
      @factory_adapter = nil
      @paranoid_mode = false
      @subxid_budget = 60
      @suite_seed = 0
    end
  end
end
