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

    def parent_id
      header["parent_id"] || parent_entries.last&.fetch("parent_id", nil)
    end

    def append_message(message)
      append_entry("message", "message" => normalize_message(message).to_h)
    end

    def append_model_change(provider:, model:)
      append_entry("model_change", "provider" => provider, "model" => model)
    end

    def append_model_change_unless_current(provider:, model:)
      current = model_change_entries.last
      return if current && current["provider"] == provider && current["model"] == model

      append_model_change(provider: provider, model: model)
    end

    def append_session_info(info)
      append_entry("session_info", "info" => info)
    end

    def append_label(label)
      append_entry("label", "label" => label.to_s)
    end

    def append_parent_id(parent_id:, parent_path: nil, forked_entry_index: nil)
      append_entry(
        "parent_id",
        {
          "parent_id" => parent_id,
          "parent_path" => parent_path,
          "forked_entry_index" => forked_entry_index
        }.compact
      )
    end

    def append_compaction(summary:, original_count:, kept_count:)
      append_entry(
        "compaction",
        "summary" => summary,
        "original_count" => original_count,
        "kept_count" => kept_count
      )
    end

    def entries
      File.foreach(path).drop(1).map { |line| JSON.parse(line) }
    end

    def append_entries(entries)
      File.open(path, "a") do |file|
        file.flock(File::LOCK_EX)
        entries.each { |entry| file.puts JSON.generate(entry) }
      ensure
        file&.flock(File::LOCK_UN)
      end
    end

    def messages
      entries.filter_map do |entry|
        next unless entry.fetch("type") == "message"

        Message.from_h(entry.fetch("message"))
      end
    end

    def compacted_messages
      compaction = compaction_entries.last
      return messages unless compaction

      all_messages = messages
      original_count = compaction.fetch("original_count")
      kept_count = compaction.fetch("kept_count")
      retained_start = [original_count - kept_count, 0].max
      [Message.system(compaction.fetch("summary"))] + all_messages.drop(retained_start)
    end

    def compact!(keep_last: Compactor::DEFAULT_KEEP_LAST)
      all_messages = messages
      compacted = Compactor.compact(all_messages, keep_last: keep_last)
      summary = compacted.first.content
      kept_count = compacted.length - 1
      append_compaction(summary: summary, original_count: all_messages.length, kept_count: kept_count)
      compacted
    end

    def compaction_entries
      entries.select { |entry| entry.fetch("type") == "compaction" }
    end

    def parent_entries
      entries.select { |entry| entry.fetch("type") == "parent_id" }
    end

    def model_change_entries
      entries.select { |entry| entry.fetch("type") == "model_change" }
    end

    def label_entries
      entries.select { |entry| entry.fetch("type") == "label" }
    end

    def labels
      initial = Array(header["labels"])
      (initial + label_entries.map { |entry| entry.fetch("label") }).uniq
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
