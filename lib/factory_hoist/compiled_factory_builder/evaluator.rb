# frozen_string_literal: true

module FactoryHoist
  module CompiledFactoryBuilder
    class Evaluator
      class << self
        attr_accessor :factory_ir
      end

      def initialize(overrides)
        @overrides = overrides.empty? ? overrides : overrides.transform_keys(&:to_sym)
        @cache = @overrides.empty? ? {} : @overrides.dup
      end

      attr_reader :instance

      def association(name, *traits_and_overrides)
        overrides = traits_and_overrides.last.is_a?(Hash) ? traits_and_overrides.pop.dup : {}
        strategy = overrides.delete(:strategy)
        strategy ||= ::FactoryBot.use_parent_strategy ? :build : :create
        if %i[build create].include?(strategy)
          return FactoryHoist.public_send(strategy, name, *traits_and_overrides, **overrides)
        end

        ::FactoryBot.public_send(strategy, name, *traits_and_overrides, **overrides)
      end

      def method_missing(name, ...)
        return @instance.send(name, ...) if @instance.respond_to?(name)
        return ::FactoryBot::SyntaxRunner.new.send(name, ...) if ::FactoryBot::SyntaxRunner.new.respond_to?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @instance.respond_to?(name) || ::FactoryBot::SyntaxRunner.new.respond_to?(name) || super
      end

      private

      def build_class
        ir = self.class.factory_ir
        return ir[:klass] if ir[:klass]

        parts = ir[:class_name].split("::").reject(&:empty?)
        return ir[:klass] = Object.const_get(parts.first, false) if parts.one?

        ir[:klass] = parts.inject(Object) { |scope, constant| scope.const_get(constant, false) }
      end
    end
  end
end
