# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module FactoryHoist
  module FastBuild
    FALLBACK = Object.new.freeze
    @compiled = {}
    @generation = 0
    @pending = {}
    @mutex = Mutex.new

    class << self
      def call(name, traits, overrides)
        return FALLBACK unless traits.empty?

        key = name.is_a?(Symbol) ? name : name.to_sym
        cached = @compiled[key]
        evaluator = cached ? cached[:evaluator] : compile(key)
        if evaluator && !overrides.empty?
          override_names = overrides.keys.map(&:to_sym)
          aliases = evaluator.factory_ir[:attributes].any? do |attribute|
            override_names.any? { |override| attribute.name != override && attribute.alias_for?(override) }
          end
          return FALLBACK if aliases
        end
        evaluator ? evaluator.new(overrides).build : FALLBACK
      end

      def compile(name)
        factory = ::FactoryBot::Internal.factory_by_name(name)
        cached = @compiled[name.to_sym]
        return cached[:evaluator] if cached && cached[:factory].equal?(factory)

        @mutex.synchronize do
          cached = @compiled[name.to_sym]
          return cached[:evaluator] if cached && cached[:factory].equal?(factory)

          ir = build_ir(factory)
          return unless ir

          install_reload_hook
          @generation += 1
          safe_name = name.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")[0, 80]
          token = "#{safe_name}_#{Process.pid}_#{factory.object_id}_#{@generation}"
          @pending[token] = ir
          path = source_path(token)
          ir[:source_path] = path
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, generated_source(token, ir))
          require path
          @compiled.fetch(name.to_sym).fetch(:evaluator)
        end
      rescue KeyError, NameError
        nil
      end

      def install(token, &builder)
        ir = @pending.delete(token)
        evaluator = Class.new(Evaluator)
        ir[:attributes].each do |attribute|
          raw_name = :"__factory_hoist_#{attribute.name}"
          evaluator.define_method(raw_name, &attribute.to_proc)
        end
        evaluator.class_eval(&builder)
        evaluator.factory_ir = ir
        @compiled[ir[:name]] = {
          factory: ir[:factory], evaluator: evaluator, source_path: ir[:source_path]
        }
      end

      def reset!
        @mutex.synchronize do
          @compiled.clear
          @pending.clear
        end
      end

      def reload!
        @mutex.synchronize do
          @compiled.each_value { |entry| entry[:evaluator].factory_ir.delete(:klass) }
        end
      end

      def source_path(token)
        File.join(Dir.tmpdir, "factory_hoist", "#{token}.rb")
      end

      def compiled_source(name)
        @compiled.dig(name.to_sym, :source_path)
      end

      private

      def install_reload_hook
        return if @reload_hook_installed
        return unless defined?(::ActiveSupport::Reloader)

        ::ActiveSupport::Reloader.to_prepare { reload! }
        @reload_hook_installed = true
      end

      def generated_source(token, ir)
        assignments = ir[:assigned].map { |name| "    object.#{name} = #{name}" }.join("\n")
        known = (ir[:assigned] | ir[:ignored]).map(&:inspect).join(", ")
        readers = ir[:attributes].map do |attribute|
          name = attribute.name
          <<~RUBY
            def #{name}
              return @cache[:#{name}] if @cache.key?(:#{name})
              @cache[:#{name}] = __factory_hoist_#{name}
            end
          RUBY
        end.join("\n")
        <<~RUBY
          FactoryHoist::FastBuild.install(#{token.dump}) do
          #{readers}
            def build
              object = @instance = build_class.new
          #{assignments}
              unless @overrides.empty?
                @overrides.each do |name, value|
                  object.public_send(:"\#{name}=", value) unless [#{known}].include?(name)
                end
              end
              object
            end
          end
        RUBY
      end

      def build_ir(factory)
        factory.compile
        definition = factory.definition
        return unless definition.callbacks.empty? && definition.constructor.nil?

        attributes = factory.send(:attributes).to_a
        klass = factory.build_class
        assigned = attributes.reject(&:ignored).map(&:name)
        names = attributes.map(&:name)
        reserved = Evaluator.instance_methods(true) | Evaluator.private_instance_methods(true) | [:build]
        required_arguments = klass.instance_method(:initialize).parameters.any? do |type, _name|
          %i[req keyreq].include?(type)
        end
        invalid_name = names.any? { |name| !name.match?(/\A[a-z_]\w*\z/i) || reserved.include?(name) }
        return if required_arguments || !klass.name || invalid_name

        {
          name: factory.name,
          factory: factory,
          class_name: klass.name,
          klass: klass,
          attributes: attributes,
          assigned: assigned,
          ignored: attributes.select(&:ignored).map(&:name)
        }
      end
    end

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
