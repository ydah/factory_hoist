# frozen_string_literal: true

module FactoryHoist
  module ParallelDatabase
    module_function

    def clone(source:, target:, adapter:)
      case adapter.respond_to?(:to_sym) && adapter.to_sym
      when :postgresql then clone_postgresql(source, target)
      when :sqlite then clone_sqlite(source, target)
      else raise ArgumentError, "parallel database cloning is unsupported for #{adapter}"
      end
    end

    def clone_sqlite(source, target)
      created = false
      complete = false
      output = nil
      File.open(source, "rb") do |file|
        file.flock(File::LOCK_EX)
        output = File.open(target, File::WRONLY | File::CREAT | File::EXCL, file.stat.mode)
        created = true
        output.binmode
        IO.copy_stream(file, output)
        output.flush
        output.fsync
        output.close
        complete = true
      end
      target
    rescue Errno::EEXIST
      raise Error, "target database already exists: #{target}"
    ensure
      output&.close unless output&.closed?
      File.unlink(target) if created && !complete && File.exist?(target)
    end
    private_class_method :clone_sqlite

    def clone_postgresql(source_url, target)
      require "pg"
      valid_target = target.is_a?(String) && target.bytesize <= 63 && target.match?(/\A[a-zA-Z0-9_]+\z/)
      raise ArgumentError, "invalid target database name" unless valid_target

      source_connection = PG.connect(source_url)
      parameters = source_connection.conninfo_hash.transform_keys(&:to_sym)
        .reject { |_key, value| value.nil? || value.empty? }
      source = parameters[:dbname]
      source_connection.close
      raise ArgumentError, "source URL must include a database" unless source

      admin = PG.connect(parameters.merge(dbname: "postgres"))
      admin.exec_params("SELECT pg_advisory_lock(hashtext($1))", ["factory_hoist_database_clone"])
      ensure_cloneable!(admin, source, target)
      admin.exec("CREATE DATABASE #{admin.quote_ident(target)} TEMPLATE #{admin.quote_ident(source)}")
      target
    ensure
      source_connection&.close unless source_connection&.finished?
      if admin && !admin.finished?
        begin
          admin.exec_params("SELECT pg_advisory_unlock(hashtext($1))", ["factory_hoist_database_clone"])
        rescue PG::Error
          nil
        ensure
          admin.close
        end
      end
    end
    private_class_method :clone_postgresql

    def ensure_cloneable!(connection, source, target)
      exists = connection.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [target]).ntuples.positive?
      raise Error, "target database already exists: #{target}" if exists

      connections = connection.exec_params(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = $1",
        [source]
      ).getvalue(0, 0).to_i
      raise Error, "source database has #{connections} active connection(s): #{source}" if connections.positive?
    end
    private_class_method :ensure_cloneable!
  end
end
