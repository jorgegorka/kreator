# frozen_string_literal: true

require "json_schemer"

module Kreator
  class ToolRegistry
    include Enumerable

    class Error < StandardError; end

    def initialize(tools = [])
      @tools = {}
      tools.each { |tool| register(tool) }
    end

    def self.default(bash_timeout: ToolContext::DEFAULT_BASH_TIMEOUT)
      new(
        [
          Tools::Read.new,
          Tools::Edit.new,
          Tools::Write.new,
          Tools::Bash.new(default_timeout: bash_timeout)
        ]
      )
    end

    def register(tool)
      raise ArgumentError, "tool name is required" if tool.name.to_s.empty?

      @tools[tool.name] = tool
      self
    end

    def each(&block)
      @tools.values.each(&block)
    end

    def names
      @tools.keys
    end

    def fetch(name)
      @tools.fetch(name.to_s) { raise Error, "unknown tool: #{name}" }
    end

    def select_names(names)
      self.class.new(Array(names).map { |name| fetch(name) })
    end

    def call(tool_call, context:, signal: nil)
      tool = fetch(tool_call.name)
      args = tool_call.arguments || {}
      validate!(tool, args)
      result = tool.call(args: args, context: context, signal: signal)
      normalize_result(result, tool_call, tool)
    rescue StandardError => error
      ToolResult.new(
        tool_call_id: tool_call.id,
        name: tool_call.name,
        content: "#{error.class}: #{error.message}",
        status: "error"
      )
    end

    private

    def validate!(tool, args)
      errors = JSONSchemer.schema(tool.schema).validate(args).to_a
      return if errors.empty?

      raise Error, errors.map { |error| error.fetch("error") }.join("; ")
    end

    def normalize_result(result, tool_call, tool)
      result = result.is_a?(ToolResult) ? result : ToolResult.from_h(result)
      return result unless result.tool_call_id.empty? || result.name.empty?

      ToolResult.new(
        tool_call_id: result.tool_call_id.empty? ? tool_call.id : result.tool_call_id,
        name: result.name.empty? ? tool.name : result.name,
        content: result.content,
        status: result.status,
        metadata: result.metadata
      )
    end
  end
end
