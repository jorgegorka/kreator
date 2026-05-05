# frozen_string_literal: true

module Kreator
  class Message
    ROLES = %w[system user assistant tool].freeze
    INITIALIZE_OPTIONS = %i[content tool_calls tool_call_id name metadata].freeze

    attr_reader :role, :content, :tool_calls, :tool_call_id, :name, :metadata

    def initialize(role:, **options)
      validate_initialize_options!(options)
      role = role.to_s
      raise ArgumentError, "unknown role: #{role.inspect}" unless ROLES.include?(role)

      content = options.fetch(:content, "")
      tool_calls = options.fetch(:tool_calls, [])
      @role = role
      @content = content.to_s
      @tool_calls = tool_calls.map { |call| call.is_a?(ToolCall) ? call : ToolCall.from_h(call) }
      @tool_call_id = options.fetch(:tool_call_id, nil)
      @name = options.fetch(:name, nil)
      @metadata = options.fetch(:metadata, {}) || {}
    end

    def self.user(content)
      new(role: "user", content: content)
    end

    def self.assistant(content, tool_calls: [])
      new(role: "assistant", content: content, tool_calls: tool_calls)
    end

    def self.system(content)
      new(role: "system", content: content)
    end

    def self.tool(content:, tool_call_id:, name: nil)
      new(role: "tool", content: content, tool_call_id: tool_call_id, name: name)
    end

    def self.from_h(hash)
      new(
        role: hash.fetch("role", hash[:role]),
        content: hash.fetch("content", hash[:content] || ""),
        tool_calls: hash.fetch("tool_calls", hash[:tool_calls] || []),
        tool_call_id: hash.fetch("tool_call_id", hash[:tool_call_id] || nil),
        name: hash.fetch("name", hash[:name] || nil),
        metadata: hash.fetch("metadata", hash[:metadata] || {})
      )
    end

    def to_h
      {
        "role" => role,
        "content" => content,
        "tool_calls" => tool_calls.map(&:to_h),
        "tool_call_id" => tool_call_id,
        "name" => name,
        "metadata" => metadata
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
