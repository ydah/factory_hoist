# frozen_string_literal: true

require "open3"
require "rbconfig"
require "active_record"

RSpec.describe "FactoryHoist lazy connection cleanup" do
  it "propagates configured connection failures before factory execution" do
    connection_handler = ActiveRecord::Base.connection_handler
    allow(connection_handler).to receive(:retrieve_connection_pool).and_return(Object.new)
    allow(ActiveRecord::Base).to receive(:connection).and_raise("connection failed")
    transaction = FactoryHoist::Runtime::Transaction.new

    expect { transaction.begin_outer }.to raise_error("connection failed")
  end

  it "starts a transaction before an example-local factory opens the connection" do
    script = <<~'RUBY'
      require "active_record"
      require "sqlite3"
      require "tempfile"
      require "factory_hoist"

      Tempfile.create(["factory_hoist_late_local", ".sqlite3"]) do |file|
        path = file.path
        file.close
        database = SQLite3::Database.new(path)
        database.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        database.close

        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: path)
        abort "connection unexpectedly eager" if ActiveRecord::Base.connected?
        model = Class.new(ActiveRecord::Base) { self.table_name = "users" }
        FactoryHoist.configuration.factory_adapter = ->(*) { model.create!(name: "local") }
        definition = FactoryHoist::Definition.new(:user, :user, [], {}, nil, "late local")
        session = FactoryHoist::Runtime::Session.new
        example = Object.new
        example.define_singleton_method(:run) do
          session.fetch(self, :user, definition, {user: definition})
        end

        session.around_example(example, local: true)

        abort "example-local row leaked" unless model.count.zero?
      end
    RUBY
    load_path = File.expand_path("../lib", __dir__)
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{load_path}", "-e", script)

    expect(status).to be_success, stderr
  end
end
