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

        cached = @compiled[name.to_sym]
        evaluator = cached ? cached[:evaluator] : compile(name)
        evaluator ? evaluator.new(overrides).build : FALLBACK
      rescue KeyError, NameError
        FALLBACK
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
          token = "#{name}_#{factory.object_id}_#{@generation}"
          @pending[token] = ir
          path = source_path(token)
          ir[:source_path] = path
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, generated_source(token, ir))
          require path
          @compiled.fetch(name.to_sym).fetch(:evaluator)
        end
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
        required_arguments = klass.instance_method(:initialize).parameters.any? do |type, _name|
          %i[req keyreq].include?(type)
        end
        return if required_arguments || !klass.name || names.any? { |name| !name.match?(/\A[a-z_]\w*\z/i) }

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
        @overrides = overrides.transform_keys(&:to_sym)
        @cache = @overrides.dup
      end

      attr_reader :instance

      def association(name, *traits_and_overrides)
        overrides = traits_and_overrides.last.is_a?(Hash) ? traits_and_overrides.pop : {}
        FactoryHoist.build(name, *traits_and_overrides, **overrides)
      end

      def method_missing(name, ...)
        return ::FactoryBot.public_send(name, ...) if ::FactoryBot.respond_to?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        ::FactoryBot.respond_to?(name) || super
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
