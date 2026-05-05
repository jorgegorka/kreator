# frozen_string_literal: true

require "json"
require "time"

module Kreator
  class Session
    VERSION = 1

    attr_reader :path, :header

    def initialize(path:, header:)
      @path = path
      @header = header
    end

    def id
      header.fetch("id")
    end

    def cwd
      header.fetch("cwd")
    end

    def append_message(message)
      append_entry("message", "message" => normalize_message(message).to_h)
    end

    def append_model_change(provider:, model:)
      append_entry("model_change", "provider" => provider, "model" => model)
    end

    def append_session_info(info)
      append_entry("session_info", "info" => info)
    end

    def entries
      File.foreach(path).drop(1).map { |line| JSON.parse(line) }
    end

    def messages
      entries.filter_map do |entry|
        next unless entry.fetch("type") == "message"

        Message.from_h(entry.fetch("message"))
      end
    end

    private

    def append_entry(type, payload)
      File.open(path, "a") do |file|
        file.flock(File::LOCK_EX)
        file.puts JSON.generate(payload.merge("type" => type, "timestamp" => Time.now.utc.iso8601(6)))
      ensure
        file&.flock(File::LOCK_UN)
      end
    end

    def normalize_message(message)
      message.is_a?(Message) ? message : Message.from_h(message)
    end
  end
end
