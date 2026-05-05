# frozen_string_literal: true

module Kreator
  class ToolResult
    STATUSES = %w[ok error].freeze

    attr_reader :tool_call_id, :name, :content, :status, :metadata

    def initialize(tool_call_id:, name:, content:, status: "ok", metadata: {})
      status = status.to_s
      raise ArgumentError, "unknown status: #{status.inspect}" unless STATUSES.include?(status)

      @tool_call_id = tool_call_id.to_s
      @name = name.to_s
      @content = content.to_s
      @status = status
      @metadata = metadata || {}
    end

    def self.from_h(hash)
      new(
        tool_call_id: hash.fetch("tool_call_id", hash[:tool_call_id]),
        name: hash.fetch("name", hash[:name]),
        content: hash.fetch("content", hash[:content] || ""),
        status: hash.fetch("status", hash[:status] || "ok"),
        metadata: hash.fetch("metadata", hash[:metadata] || {})
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
        "metadata" => metadata
      }.compact
    end
  end
end
