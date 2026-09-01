# frozen_string_literal: true

require "bundler/setup"
require "factory_hoist"

class BenchFastBuildUser
  attr_accessor :first_name, :last_name, :email, :age, :city, :active
end

FactoryBot.define do
  factory :bench_fast_build_user do
    first_name { "Ada" }
    last_name { "Lovelace" }
    email { "#{first_name.downcase}.#{last_name.downcase}@example.test" }
    age { 36 }
    city { "London" }
    active { true }
  end
end

iterations = Integer(ENV.fetch("N", 20_000))
FactoryHoist.build(:bench_fast_build_user)

measure = lambda do |&block|
  3.times.map do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    iterations.times(&block)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end.sort[1]
end

factory_bot = measure.call { FactoryBot.build(:bench_fast_build_user) }
factory_hoist = measure.call { FactoryHoist.build(:bench_fast_build_user) }
speedup = factory_bot / factory_hoist

puts format("FactoryBot %.3fs / FactoryHoist %.3fs / %.2fx", factory_bot, factory_hoist, speedup)
abort "Fast Build did not reach 5x" if speedup < 5
