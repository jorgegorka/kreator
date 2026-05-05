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
      raise Error, "duplicate tool: #{tool.name}" if @tools.key?(tool.name)

      @tools[tool.name] = tool
      self
    end

    def each(&)
      @tools.values.each(&)
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
      context.ensure_not_cancelled!(signal)
      tool = fetch(tool_call.name)
      args = tool_call.arguments || {}
      validate!(tool, args)
      result = tool.call(args: args, context: context, signal: signal)
      context.ensure_not_cancelled!(signal)
      normalize_result(result, tool_call, tool)
    rescue StandardError => e
      structured_error = error_payload(e)
      ToolResult.new(
        tool_call_id: tool_call.id,
        name: tool_call.name,
        content: "#{structured_error.fetch('code')}: #{e.message}",
        status: "error",
        error: structured_error
      )
    end

    private

    def validate!(tool, args)
      errors = JSONSchemer.schema(tool.schema).validate(args).to_a
      return if errors.empty?

      raise ToolError.new(errors.map { |error| error.fetch("error") }.join("; "), code: "validation_error")
    end

    def normalize_result(result, tool_call, tool)
      result = ToolResult.from_h(result) unless result.is_a?(ToolResult)
      return result unless result.tool_call_id.empty? || result.name.empty?

      ToolResult.new(
        tool_call_id: result.tool_call_id.empty? ? tool_call.id : result.tool_call_id,
        name: result.name.empty? ? tool.name : result.name,
        content: result.content,
        status: result.status,
        metadata: result.metadata,
        error: result.error
      )
    end

    def error_payload(error)
      return error.to_h if error.respond_to?(:to_h) && error.is_a?(ToolError)

      code =
        case error
        when JSONSchemer::InvalidSchema
          "validation_error"
        when Errno::ENOENT
          "not_found"
        when Timeout::Error
          "timeout"
        when Interrupt
          "cancelled"
        else
          "runtime_error"
        end

      {
        "code" => code,
        "class" => error.class.name,
        "message" => error.message,
        "details" => {}
      }
    end
  end
end
