# frozen_string_literal: true

module Kreator
  class PluginTool
    class << self
      def tool_name(value = nil)
        @tool_name = value.to_s if value
        @tool_name
      end

      def description(value = nil)
        @description = value.to_s if value
        @description.to_s
      end

      def schema(value = nil)
        @schema = value if value
        @schema || {}
      end
    end

    def call(args:, context:, signal:)
      raise NotImplementedError, "#{self.class} must implement #call"
    end
  end

  class PluginToolAdapter
    attr_reader :plugin, :instance

    def initialize(plugin:, instance:)
      @plugin = plugin
      @instance = instance
    end

    def name
      "#{plugin.name}.#{tool_name}"
    end

    def tool_name
      instance.class.tool_name
    end

    def description
      instance.class.description
    end

    def schema
      instance.class.schema
    end

    def call(args:, context:, signal:)
      context.approve_plugin_tool!(
        plugin: plugin.name,
        tool: name,
        description: description,
        args: args
      )
      result = instance.call(args: args, context: context, signal: signal)
      annotate_result(result)
    end

    def to_h
      {
        "plugin" => plugin.name,
        "name" => name,
        "tool_name" => tool_name,
        "description" => description,
        "schema" => schema
      }
    end

    private

    def annotate_result(result)
      result = ToolResult.from_h(result) unless result.is_a?(ToolResult)
      ToolResult.new(
        tool_call_id: result.tool_call_id,
        name: result.name,
        content: result.content,
        status: result.status,
        metadata: result.metadata.merge("plugin" => plugin.name, "plugin_tool" => tool_name),
        error: result.error
      )
    end
  end

  class PluginToolLoader
    NAME_PATTERN = /\A[a-zA-Z0-9_-]+\z/

    def load_tools(plugins)
      tools = plugins.flat_map { |plugin| load_plugin_tools(plugin) }
      ensure_unique!(tools)
      tools
    end

    def validate(plugin)
      load_plugin_tools(plugin)
      []
    rescue StandardError => e
      [e.message]
    end

    private

    def load_plugin_tools(plugin)
      plugin.tool_specs.filter_map do |spec|
        next unless spec.fetch("enabled", true)

        load_tool(plugin, spec)
      end
    end

    def load_tool(plugin, spec)
      raise ArgumentError, "plugin tool path is required" if spec["path"].to_s.empty?
      raise ArgumentError, "plugin tool class is required" if spec["class"].to_s.empty?

      tool_path = plugin.expand_path_inside!(spec.fetch("path"))
      load tool_path
      klass = constantize(spec.fetch("class"))
      raise ArgumentError, "#{klass} must inherit from Kreator::PluginTool" unless klass < PluginTool

      validate_tool_class!(klass)
      PluginToolAdapter.new(plugin: plugin, instance: klass.new)
    end

    def validate_tool_class!(klass)
      raise ArgumentError, "#{klass} must declare tool_name" if klass.tool_name.to_s.empty?
      raise ArgumentError, "#{klass} tool_name is invalid: #{klass.tool_name}" unless klass.tool_name.match?(NAME_PATTERN)
      raise ArgumentError, "#{klass} must declare description" if klass.description.to_s.empty?
      raise ArgumentError, "#{klass} schema must be a Hash" unless klass.schema.is_a?(Hash)
    end

    def constantize(name)
      name.to_s.split("::").reject(&:empty?).inject(Object) do |namespace, constant|
        namespace.const_get(constant, false)
      end
    rescue NameError
      raise ArgumentError, "plugin tool class not found: #{name}"
    end

    def ensure_unique!(tools)
      seen = {}
      tools.each do |tool|
        raise ArgumentError, "duplicate plugin tool: #{tool.name}" if seen[tool.name]

        seen[tool.name] = true
      end
    end
  end
end
