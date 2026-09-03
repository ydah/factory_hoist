# frozen_string_literal: true

require "tempfile"
require "sqlite3"
require "factory_hoist/database_cloning"

RSpec.describe FactoryHoist::DatabaseCloning do
  it "clones SQLite databases without overwriting an existing target" do
    Tempfile.create("factory_hoist_source") do |source|
      database = SQLite3::Database.new(source.path)
      database.execute("CREATE TABLE proof(value TEXT NOT NULL)")
      database.execute("INSERT INTO proof VALUES ('cloned')")
      database.close
      File.chmod(0o444, source.path)
      target = "#{source.path}_worker"

      described_class.clone(source: source.path, target: target, adapter: :sqlite)

      clone = SQLite3::Database.new(target, readonly: true)
      expect(clone.get_first_value("SELECT value FROM proof")).to eq("cloned")
      expect(File.stat(target).mode & 0o777).to eq(0o444)
      clone.close
      expect { described_class.clone(source: source.path, target: target, adapter: :sqlite) }
        .to raise_error(FactoryHoist::Error, /already exists/)
      clone = SQLite3::Database.new(target, readonly: true)
      expect(clone.get_first_value("SELECT value FROM proof")).to eq("cloned")
      clone.close
    ensure
      clone&.close unless clone&.closed?
      database&.close unless database&.closed?
      File.unlink(target) if target && File.exist?(target)
    end
  end

  it "includes committed WAL data after an unclean source shutdown" do
    Tempfile.create("factory_hoist_wal_source") do |source|
      source.close
      writer = fork do
        database = SQLite3::Database.new(source.path)
        database.execute("PRAGMA journal_mode=WAL")
        database.execute("PRAGMA wal_autocheckpoint=0")
        database.execute("CREATE TABLE proof(value TEXT NOT NULL)")
        database.execute("INSERT INTO proof VALUES ('committed')")
        exit!
      end
      Process.wait(writer)
      target = "#{source.path}_worker"

      described_class.clone(source: source.path, target: target, adapter: :sqlite)

      clone = SQLite3::Database.new(target)
      expect(clone.get_first_value("SELECT value FROM proof")).to eq("committed")
    ensure
      clone&.close unless clone&.closed?
      [target, "#{source.path}-wal", "#{source.path}-shm"].compact.each do |path|
        File.unlink(path) if File.exist?(path)
      end
    end
  end

  it "rejects adapters without a safe clone primitive" do
    expect { described_class.clone(source: "a", target: "b", adapter: :mysql) }
      .to raise_error(ArgumentError, /unsupported/)
    expect { described_class.clone(source: "a", target: "b", adapter: nil) }
      .to raise_error(ArgumentError, /unsupported/)
  end

  it "rejects PostgreSQL names that would be truncated" do
    expect { described_class.clone(source: "postgresql:///postgres", target: "a" * 64, adapter: :postgresql) }
      .to raise_error(ArgumentError, /invalid target/)
  end
end
