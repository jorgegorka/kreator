# frozen_string_literal: true

module Kreator
  class ToolResult
    STATUSES = %w[ok error].freeze
    INITIALIZE_OPTIONS = %i[status metadata error].freeze

    attr_reader :tool_call_id, :name, :content, :status, :metadata, :error

    def initialize(tool_call_id:, name:, content:, **options)
      validate_initialize_options!(options)
      status = options.fetch(:status, "ok")
      status = status.to_s
      raise ArgumentError, "unknown status: #{status.inspect}" unless STATUSES.include?(status)

      @tool_call_id = tool_call_id.to_s
      @name = name.to_s
      @content = content.to_s
      @status = status
      @metadata = options.fetch(:metadata, {}) || {}
      @error = options.fetch(:error, nil)
    end

    def self.from_h(hash)
      new(
        tool_call_id: hash.fetch("tool_call_id", hash[:tool_call_id]),
        name: hash.fetch("name", hash[:name]),
        content: hash.fetch("content", hash[:content] || ""),
        status: hash.fetch("status", hash[:status] || "ok"),
        metadata: hash.fetch("metadata", hash[:metadata] || {}),
        error: hash.fetch("error", hash[:error] || nil)
      )
    end

    def to_message
      Message.tool(content: content, tool_call_id: tool_call_id, name: name)
    end

    def to_h
      {
        "tool_call_id" => tool_call_id,
        "name" => name,
        "content" => content,
        "status" => status,
        "metadata" => metadata,
        "error" => error
      }.compact
    end

    private

    def validate_initialize_options!(options)
      unknown = options.keys - INITIALIZE_OPTIONS
      return if unknown.empty?

      raise ArgumentError, "unknown keyword: #{unknown.first.inspect}"
    end
  end
end
