# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module Kreator
  class SessionManager
    DEFAULT_SESSION_DIR = File.expand_path("~/.kreator/sessions")

    attr_reader :session_dir

    def initialize(session_dir: DEFAULT_SESSION_DIR)
      @session_dir = File.expand_path(session_dir)
    end

    def create(cwd:, parent_id: nil, parent_path: nil, forked_entry_index: nil)
      cwd = File.expand_path(cwd)
      id = SecureRandom.uuid
      timestamp = Time.now.utc.iso8601(6)
      directory = directory_for(cwd)
      FileUtils.mkdir_p(directory)
      path = File.join(directory, "#{timestamp.tr(':', '-')}_#{id}.jsonl")
      header = {
        "type" => "session_header",
        "version" => Session::VERSION,
        "id" => id,
        "timestamp" => timestamp,
        "cwd" => cwd
      }.compact
      header["parent_id"] = parent_id if parent_id
      header["parent_path"] = parent_path if parent_path
      header["forked_entry_index"] = forked_entry_index unless forked_entry_index.nil?
      File.write(path, "#{JSON.generate(header)}\n")
      Session.new(path: path, header: header)
    end

    def open(path:)
      resolved = resolve_path(path)
      raise ArgumentError, "session not found: #{path}" unless resolved && File.file?(resolved)

      header = JSON.parse(File.open(resolved, &:readline))
      raise ArgumentError, "invalid session header in #{resolved}" unless header.fetch("type") == "session_header"

      Session.new(path: resolved, header: header)
    end

    def continue_recent(cwd:)
      sessions = list(cwd: cwd)
      raise ArgumentError, "no sessions found for #{File.expand_path(cwd)}" if sessions.empty?

      self.open(path: sessions.first.fetch("path"))
    end

    def list(cwd:)
      directory = directory_for(File.expand_path(cwd))
      return [] unless Dir.exist?(directory)

      summaries_in(File.join(directory, "*.jsonl"))
    end

    def fork(path:, entry_index: nil)
      source = self.open(path: path)
      source_entries = source.entries
      resolved_index = entry_index.nil? ? source_entries.length - 1 : Integer(entry_index)
      raise ArgumentError, "cannot fork an empty session" if resolved_index.negative?
      raise ArgumentError, "entry index out of range: #{resolved_index}" if resolved_index >= source_entries.length

      forked = create(
        cwd: source.cwd,
        parent_id: source.id,
        parent_path: source.path,
        forked_entry_index: resolved_index
      )
      forked.append_parent_id(parent_id: source.id, parent_path: source.path, forked_entry_index: resolved_index)
      forked.append_entries(source_entries.first(resolved_index + 1))
      forked
    end

    def branches(parent_id:)
      matching_branches = Dir.glob(File.join(session_dir, "*", "*.jsonl")).filter_map do |path|
        summary = session_summary(path)
        summary if summary && summary["parent_id"] == parent_id
      end
      matching_branches.sort_by { |summary| summary.fetch("timestamp") }.reverse
    end

    def label(path:, label:)
      session = self.open(path: path)
      session.append_label(label)
      session
    end

    def search(query:, cwd: nil)
      query = query.to_s.downcase
      pattern = cwd ? File.join(directory_for(File.expand_path(cwd)), "*.jsonl") : File.join(session_dir, "*", "*.jsonl")
      summaries_in(pattern).select do |summary|
        searchable = [
          summary["id"],
          summary["cwd"],
          summary["timestamp"],
          summary["provider"],
          summary["model"],
          *Array(summary["labels"]),
          transcript(path: summary.fetch("path"), format: "plain")
        ].compact.join("\n").downcase
        searchable.include?(query)
      end
    end

    def export(path:, format: "json")
      session = self.open(path: path)
      case format.to_s
      when "json"
        JSON.pretty_generate(
          "header" => session.header,
          "entries" => session.entries
        )
      when "jsonl"
        File.read(session.path)
      when "markdown", "md"
        transcript(path: session.path, format: "markdown")
      when "plain", "text"
        transcript(path: session.path, format: "plain")
      else
        raise ArgumentError, "unknown export format: #{format}"
      end
    end

    def transcript(path:, format: "markdown")
      session = self.open(path: path)
      session.messages.map do |message|
        case format.to_s
        when "markdown", "md"
          transcript_markdown(message)
        when "plain", "text"
          transcript_plain(message)
        else
          raise ArgumentError, "unknown transcript format: #{format}"
        end
      end.join("\n\n")
    end

    def cleanup(cwd: nil, empty: false, failed: false)
      raise ArgumentError, "cleanup requires empty: true or failed: true" unless empty || failed

      deleted = []
      summaries_in(cleanup_pattern(cwd)).each do |summary|
        session = self.open(path: summary.fetch("path"))
        next unless cleanup_session?(session, empty: empty, failed: failed)

        FileUtils.rm_f(session.path)
        deleted << summary
      end
      deleted
    end

    private

    def cleanup_pattern(cwd)
      return File.join(session_dir, "*", "*.jsonl") unless cwd

      File.join(directory_for(File.expand_path(cwd)), "*.jsonl")
    end

    def cleanup_session?(session, empty:, failed:)
      return true if empty && session.messages.empty?
      return true if failed && failed_session?(session)

      false
    end

    def summaries_in(pattern)
      Dir.glob(pattern)
         .map { |path| session_summary(path) }
         .compact
         .sort_by { |summary| summary.fetch("timestamp") }
         .reverse
    end

    def directory_for(cwd)
      File.join(session_dir, encode_cwd(cwd))
    end

    def encode_cwd(cwd)
      "--#{cwd.bytes.map { |byte| byte.to_s(16).rjust(2, '0') }.join}--"
    end

    def resolve_path(path_or_id)
      expanded = File.expand_path(path_or_id)
      return expanded if File.file?(expanded)

      Dir.glob(File.join(session_dir, "*", "*.jsonl")).find do |path|
        JSON.parse(File.open(path, &:readline)).fetch("id") == path_or_id
      rescue JSON::ParserError, KeyError, EOFError
        false
      end
    end

    def session_summary(path)
      header = JSON.parse(File.open(path, &:readline))
      return unless header["type"] == "session_header"

      session = Session.new(path: path, header: header)
      last_model_change = session.entries.reverse.find { |entry| entry.fetch("type") == "model_change" }
      header.merge(
        "path" => path,
        "labels" => session.labels,
        "message_count" => session.messages.length,
        "provider" => last_model_change&.fetch("provider", nil),
        "model" => last_model_change&.fetch("model", nil)
      )
    rescue JSON::ParserError, KeyError, EOFError
      nil
    end

    def transcript_markdown(message)
      title = message.role == "tool" ? "tool: #{message.name || message.tool_call_id}" : message.role
      "### #{title}\n\n#{message.content}"
    end

    def transcript_plain(message)
      title = message.role == "tool" ? "tool: #{message.name || message.tool_call_id}" : message.role
      "#{title}:\n#{message.content}"
    end

    def failed_session?(session)
      session.entries.any? do |entry|
        entry.fetch("type") == "message" &&
          entry.dig("message", "role") == "tool" &&
          entry.dig("message", "metadata", "status") == "error"
      end
    end
  end
end
