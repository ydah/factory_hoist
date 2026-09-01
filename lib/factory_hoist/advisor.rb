# frozen_string_literal: true

module FactoryHoist
  class Advisor
    HOIST = /\bhoist\s*\(?\s*:(\w+)/
    FACTORY_CALL = /\b(create|build|create_list|build_list)\s*\(\s*:(\w+)[^\n]*\)/

    def initialize(paths)
      @paths = paths
    end

    def print(io)
      findings = scan
      if findings.empty?
        io.puts "No factory hoist suggestions."
      else
        findings.each { |finding| io.puts finding }
      end
      print_runtime_stats(io)
      findings
    end

    private

    def scan
      files.flat_map { |file| findings_for(file) }
    end

    def files
      @paths.flat_map do |path|
        File.directory?(path) ? Dir.glob(File.join(path, "**", "*_spec.rb")) : path
      end.select { |path| File.file?(path) }.uniq.sort
    end

    def findings_for(file)
      source = File.read(file)
      unused = source.to_enum(:scan, HOIST).filter_map do
        match = Regexp.last_match
        name = match[1]
        next if source.scan(/\b#{Regexp.escape(name)}\b/).size > 1

        "#{file}:#{source[0...match.begin(0)].count("\n") + 1}: unused hoist :#{name}"
      end
      calls = source.scan(FACTORY_CALL).tally.filter_map do |(strategy, name), count|
        next unless count > 1

        "#{file}: repeated #{strategy}(:#{name}) x#{count}; consider hoist(:#{name})"
      end
      unused + calls
    end

    def print_runtime_stats(io)
      stats = FactoryHoist.stats.to_h
      return if stats[:references].zero? && stats[:materializations].zero?

      io.puts format(
        "Runtime: %d materializations, %d references, %.1f%% degraded",
        stats[:materializations], stats[:references], stats[:degradation_rate] * 100
      )
      stats[:materialization_costs].first(20).each do |key, seconds|
        io.puts format("  %.3fs %s", seconds, key)
      end
    end
  end
end
