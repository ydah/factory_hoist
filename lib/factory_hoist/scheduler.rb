# frozen_string_literal: true

module FactoryHoist
  module Scheduler
    extend self

    def install!
      schedules = Hash.new { |hash, group| hash[group] = {} }
      definitions.each do |group, own_definitions|
        schedules[group]
        own_definitions.each_value do |definition|
          examples = referring_examples(group, definition)
          next if examples.empty?

          target = lca(examples.map(&:example_group))
          schedules[target][definition.name] = definition
        end
      end
      schedules.each { |group, scheduled| install_hooks(group, scheduled) }
    end

    def definitions_for(group)
      group.parent_groups.reverse_each.with_object({}) do |ancestor, available|
        available.merge!(ancestor.instance_variable_get(:@factory_hoist_definitions) || {})
      end
    end

    private

    def definitions
      ::RSpec.world.example_groups.flat_map(&:descendants).filter_map do |group|
        own = group.instance_variable_get(:@factory_hoist_definitions)
        [group, own] if own && !own.empty?
      end
    end

    def referring_examples(declaration_group, definition)
      return [] unless hoistable_definition?(declaration_group, definition)

      declaration_group.descendant_filtered_examples.select do |example|
        available = definitions_for(example.example_group)
        next false unless available[definition.name].equal?(definition)

        references?(example.instance_variable_get(:@example_block), definition.name) ||
          dependent_definition_references?(example.example_group, definition.name)
      end
    end

    def hoistable_definition?(group, definition)
      return false unless hoistable_factory?(definition)
      return true unless definition.block
      return false unless defined?(RubyVM::InstructionSequence)

      available = definitions_for(group).keys.map(&:to_s)
      disassembly = RubyVM::InstructionSequence.of(definition.block).disasm
      return false if disassembly.include?("getinstancevariable")

      implicit_calls = disassembly.scan(
        /mid:([^,\s]+), argc:\d+, [^>]*(?:FCALL|VCALL)/
      ).flatten
      (implicit_calls - available).empty?
    rescue StandardError
      false
    end

    def hoistable_factory?(definition)
      return true if FactoryHoist.configuration.factory_adapter

      factory = ::FactoryBot::Internal.factory_by_name(definition.factory).with_traits(definition.traits)
      factory.compile
      factory.definition.constructor.nil? && factory.definition.to_create.nil?
    rescue KeyError
      true
    end

    def dependent_definition_references?(group, name)
      available = definitions_for(group)
      directly_referenced = referenced_names(group, available)
      directly_referenced.any? { |referenced| depends_on?(available, referenced, name, {}) }
    end

    def referenced_names(group, available)
      group.filtered_examples.flat_map do |example|
        available.keys.select { |name| references?(example.instance_variable_get(:@example_block), name) }
      end.uniq
    end

    def depends_on?(available, current, target, seen)
      return true if current == target
      return false if seen[current]

      seen[current] = true
      definition = available[current]
      return false unless definition&.block

      available.keys.any? do |name|
        references?(definition.block, name, symbols: true) && depends_on?(available, name, target, seen)
      end
    end

    def references?(block, name, symbols: false)
      # ponytail: MRI bytecode finds direct calls cheaply; unsupported/dynamic calls deopt locally.
      return true unless defined?(RubyVM::InstructionSequence)

      disassembly = RubyVM::InstructionSequence.of(block)&.disasm.to_s
      disassembly.include?("mid:#{name}, argc:0") || (symbols && disassembly.include?(":#{name}"))
    rescue StandardError
      true
    end

    def lca(groups)
      groups.first.parent_groups.find { |candidate| groups.all? { |group| group.parent_groups.include?(candidate) } }
    end

    def install_hooks(group, definitions)
      group.prepend_before(:context) do
        next unless self.class.equal?(group)

        Runtime.current.enter(group, definitions, materialize: false)
      end
      group.before(:context) do
        next unless self.class.equal?(group)

        Runtime.current.materialize(group)
      end
      group.append_after(:context) do
        next unless self.class.equal?(group)

        Runtime.current.leave(group)
      end
    end
  end
end
