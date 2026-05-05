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

    def create(cwd:)
      cwd = File.expand_path(cwd)
      id = SecureRandom.uuid
      timestamp = Time.now.utc.iso8601(6)
      directory = directory_for(cwd)
      FileUtils.mkdir_p(directory)
      path = File.join(directory, "#{timestamp.tr(":", "-")}_#{id}.jsonl")
      header = {
        "type" => "session_header",
        "version" => Session::VERSION,
        "id" => id,
        "timestamp" => timestamp,
        "cwd" => cwd
      }
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

      open(path: sessions.first.fetch("path"))
    end

    def list(cwd:)
      directory = directory_for(File.expand_path(cwd))
      return [] unless Dir.exist?(directory)

      Dir.children(directory)
         .grep(/\.jsonl\z/)
         .map { |name| session_summary(File.join(directory, name)) }
         .compact
         .sort_by { |summary| summary.fetch("timestamp") }
         .reverse
    end

    private

    def directory_for(cwd)
      File.join(session_dir, encode_cwd(cwd))
    end

    def encode_cwd(cwd)
      "--#{cwd.bytes.map { |byte| byte.to_s(16).rjust(2, "0") }.join}--"
    end

    def resolve_path(path_or_id)
      expanded = File.expand_path(path_or_id)
      return expanded if File.file?(expanded)

      Dir.glob(File.join(session_dir, "*", "*.jsonl")).find do |path|
        begin
          JSON.parse(File.open(path, &:readline)).fetch("id") == path_or_id
        rescue JSON::ParserError, KeyError, EOFError
          false
        end
      end
    end

    def session_summary(path)
      header = JSON.parse(File.open(path, &:readline))
      return unless header["type"] == "session_header"

      header.merge("path" => path)
    rescue JSON::ParserError, KeyError, EOFError
      nil
    end
  end
end
