# frozen_string_literal: true

require "tempfile"
require "factory_hoist/parallel_database"

RSpec.describe FactoryHoist::ParallelDatabase do
  it "clones SQLite files without overwriting an existing target" do
    Tempfile.create("factory_hoist_source") do |source|
      source.write("database")
      source.flush
      target = "#{source.path}_worker"

      described_class.clone(source: source.path, target: target, adapter: :sqlite)

      expect(File.binread(target)).to eq("database")
      expect { described_class.clone(source: source.path, target: target, adapter: :sqlite) }
        .to raise_error(FactoryHoist::Error, /already exists/)
      expect(File.binread(target)).to eq("database")
    ensure
      File.unlink(target) if target && File.exist?(target)
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
