# frozen_string_literal: true

module Kreator
  class ToolCall
    attr_reader :id, :name, :arguments, :raw_arguments, :metadata

    def initialize(id:, name:, arguments: {}, raw_arguments: nil, metadata: {})
      @id = id.to_s
      @name = name.to_s
      @arguments = arguments || {}
      @raw_arguments = raw_arguments
      @metadata = metadata || {}
    end

    def self.from_h(hash)
      new(
        id: hash.fetch("id", hash[:id]),
        name: hash.fetch("name", hash[:name]),
        arguments: hash.fetch("arguments", hash[:arguments] || {}),
        raw_arguments: hash.fetch("raw_arguments", hash[:raw_arguments] || nil),
        metadata: hash.fetch("metadata", hash[:metadata] || {})
      )
    end

    def to_h
      {
        "id" => id,
        "name" => name,
        "arguments" => arguments,
        "raw_arguments" => raw_arguments,
        "metadata" => metadata
      }.compact
    end
  end
end
