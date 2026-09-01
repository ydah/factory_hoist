# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "FactoryHoist load order" do
  it "installs both supported test-framework adapters from the primary entrypoint" do
    script = <<~'RUBY'
      require "factory_hoist"
      abort "RSpec DSL missing" unless RSpec::Core::ExampleGroup.respond_to?(:hoist)
      abort "Minitest DSL missing" unless Minitest::Test.respond_to?(:hoist)
    RUBY
    load_path = File.expand_path("../lib", __dir__)
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{load_path}", "-e", script)

    expect(status).to be_success, stderr
  end
end
