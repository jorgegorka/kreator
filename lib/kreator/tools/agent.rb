# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "shellwords"
require "time"

module Kreator
  module Tools
    class Agent
      DEFAULT_MAX_OUTPUT_BYTES = 20_000
      DEFAULT_WAIT_TIMEOUT = 1

      def name
        "agent"
      end

      def description
        "Start, inspect, wait for, or stop a headless Kreator child agent in a detached tmux session."
      end

      def schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["action"],
          "properties" => {
            "action" => { "type" => "string", "enum" => %w[start capture wait stop list] },
            "prompt" => { "type" => "string", "minLength" => 1 },
            "id" => { "type" => "string", "minLength" => 1 },
            "name" => { "type" => "string", "minLength" => 1 },
            "provider" => { "type" => "string", "minLength" => 1 },
            "model" => { "type" => "string", "minLength" => 1 },
            "tools" => {
              "type" => "array",
              "items" => { "type" => "string", "minLength" => 1 }
            },
            "no_tools" => { "type" => "boolean" },
            "session" => { "type" => "boolean" },
            "timeout_seconds" => { "type" => "integer", "minimum" => 1 },
            "max_output_bytes" => { "type" => "integer", "minimum" => 1 }
          }
        }
      end

      def call(args:, context:, signal:)
        context.ensure_not_cancelled!(signal)

        case args.fetch("action")
        when "start"
          start_agent(args, context, signal)
        when "capture"
          capture_agent(args, signal)
        when "wait"
          wait_for_agent(args, signal)
        when "stop"
          stop_agent(args, context, signal)
        when "list"
          list_agents(args, signal)
        end
      end

      private

      def start_agent(args, context, signal)
        prompt = required_arg(args, "prompt", "start")
        context.approve!(
          action: :agent,
          target: prompt,
          details: { "cwd" => context.cwd, "provider" => args["provider"], "model" => args["model"] }
        )
        ensure_tmux_available!
        context.ensure_not_cancelled!(signal)

        record = build_record(args, context)
        FileUtils.mkdir_p(agent_home)
        File.write(record.fetch("path"), JSON.pretty_generate(record))

        _stdout, stderr, status = Open3.capture3(
          "tmux",
          "new-session",
          "-d",
          "-s",
          record.fetch("tmux_session"),
          "-c",
          context.cwd,
          command_for(record, prompt, args)
        )
        raise ToolError.new("tmux failed to start child agent: #{stderr.strip}", code: "runtime_error") unless status.success?

        ToolResult.new(
          tool_call_id: "",
          name: name,
          content: "started agent #{record.fetch('id')} in tmux session #{record.fetch('tmux_session')}",
          metadata: record.merge("running" => tmux_session_running?(record.fetch("tmux_session")))
        )
      end

      def capture_agent(args, signal)
        record = load_record(required_arg(args, "id", "capture"))
        signal_check(signal)
        max_output_bytes = args.fetch("max_output_bytes", DEFAULT_MAX_OUTPUT_BYTES)
        output = read_tail(record.fetch("log_path"), max_output_bytes)
        status = read_status(record)
        running = tmux_session_running?(record.fetch("tmux_session"))

        ToolResult.new(
          tool_call_id: "",
          name: name,
          content: output.empty? ? "(no output yet)" : output,
          metadata: record.merge("status_record" => status, "running" => running)
        )
      end

      def wait_for_agent(args, signal)
        record = load_record(required_arg(args, "id", "wait"))
        timeout = args.fetch("timeout_seconds", DEFAULT_WAIT_TIMEOUT)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

        loop do
          signal_check(signal)
          status = read_status(record)
          return wait_result(record, status, true, args) if status
          return wait_result(record, nil, false, args) if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.1
        end
      end

      def stop_agent(args, context, signal)
        record = load_record(required_arg(args, "id", "stop"))
        context.approve!(action: :agent, target: record.fetch("id"), details: { "tmux_session" => record.fetch("tmux_session") })
        signal_check(signal)

        _stdout, stderr, status = Open3.capture3("tmux", "kill-session", "-t", record.fetch("tmux_session"))
        raise ToolError.new("tmux failed to stop child agent: #{stderr.strip}", code: "runtime_error") unless status.success? || stderr.include?("can't find session")

        stopped = {
          "id" => record.fetch("id"),
          "stopped" => true,
          "exit_status" => nil,
          "finished_at" => Time.now.utc.iso8601
        }
        File.write(record.fetch("status_path"), JSON.pretty_generate(stopped))

        ToolResult.new(
          tool_call_id: "",
          name: name,
          content: "stopped agent #{record.fetch('id')}",
          metadata: record.merge("status_record" => stopped, "running" => false)
        )
      end

      def list_agents(args, signal)
        max_output_bytes = args.fetch("max_output_bytes", DEFAULT_MAX_OUTPUT_BYTES)
        agents = Dir.glob(File.join(agent_home, "*.json")).map do |path|
          record = JSON.parse(File.read(path))
          record.merge(
            "status_record" => read_status(record),
            "running" => tmux_session_running?(record.fetch("tmux_session"))
          )
        rescue JSON::ParserError
          nil
        ensure
          signal_check(signal)
        end.compact

        content = JSON.pretty_generate(agents.map { |record| compact_record(record) })
        ToolResult.new(
          tool_call_id: "",
          name: name,
          content: content.bytesize > max_output_bytes ? "#{content.byteslice(0, max_output_bytes)}\n[truncated]" : content,
          metadata: { "count" => agents.length, "agent_home" => agent_home }
        )
      end

      def wait_result(record, status, completed, args)
        max_output_bytes = args.fetch("max_output_bytes", DEFAULT_MAX_OUTPUT_BYTES)
        output = read_tail(record.fetch("log_path"), max_output_bytes)
        ToolResult.new(
          tool_call_id: "",
          name: name,
          content: completed ? output : "agent #{record.fetch('id')} is still running",
          status: completed ? status_for(status) : "ok",
          metadata: record.merge(
            "completed" => completed,
            "status_record" => status,
            "running" => tmux_session_running?(record.fetch("tmux_session"))
          ),
          error: error_for(status)
        )
      end

      def build_record(args, context)
        id = "agent_#{SecureRandom.hex(6)}"
        session_name = tmux_session_name(args["name"], id)
        {
          "id" => id,
          "name" => args["name"],
          "cwd" => context.cwd,
          "tmux_session" => session_name,
          "path" => File.join(agent_home, "#{id}.json"),
          "log_path" => File.join(agent_home, "#{id}.log"),
          "status_path" => File.join(agent_home, "#{id}.status.json"),
          "provider" => args["provider"],
          "model" => args["model"],
          "tools" => args["tools"],
          "no_tools" => args.fetch("no_tools", false),
          "session" => args.fetch("session", false),
          "started_at" => Time.now.utc.iso8601
        }.compact
      end

      def command_for(record, prompt, args)
        child_args = []
        child_args += ["--provider", args["provider"]] if args["provider"]
        child_args += ["--model", args["model"]] if args["model"]
        child_args += ["--tools", args.fetch("tools").join(",")] if args["tools"]
        child_args << "--no-tools" if args["no_tools"]
        child_args << "--no-session" unless args["session"]
        child_args << "--json"
        child_args << prompt

        command = ([RbConfig.ruby, executable_path] + child_args).shelljoin
        status_writer = status_writer_command(record)
        "#{command} > #{record.fetch('log_path').shellescape} 2>&1; #{status_writer}"
      end

      def status_writer_command(record)
        ruby = RbConfig.ruby.shellescape
        status_path = record.fetch("status_path").shellescape
        id = record.fetch("id").shellescape
        "#{ruby} -rjson -rtime -e #{status_writer_script.shellescape} -- #{status_path} #{id} $?"
      end

      def status_writer_script
        "File.write(ARGV[0], JSON.pretty_generate('id'=>ARGV[1], 'exit_status'=>ARGV[2].to_i, 'finished_at'=>Time.now.utc.iso8601))"
      end

      def executable_path
        ENV.fetch("KREATOR_AGENT_EXECUTABLE") do
          File.expand_path("../../../exe/kreator", __dir__)
        end
      end

      def tmux_session_name(label, id)
        slug = label.to_s.downcase.gsub(/[^a-z0-9_.-]+/, "-").gsub(/\A-+|-+\z/, "")
        slug = "child" if slug.empty?
        "kreator-#{slug[0, 32]}-#{id.delete_prefix('agent_')}"
      end

      def ensure_tmux_available!
        _stdout, _stderr, status = Open3.capture3("tmux", "-V")
        return if status.success?

        raise ToolError.new("tmux is required for the agent tool", code: "not_found")
      rescue Errno::ENOENT
        raise ToolError.new("tmux is required for the agent tool", code: "not_found")
      end

      def tmux_session_running?(session_name)
        _stdout, _stderr, status = Open3.capture3("tmux", "has-session", "-t", session_name)
        status.success?
      rescue Errno::ENOENT
        false
      end

      def load_record(id)
        path = File.join(agent_home, "#{id}.json")
        raise ArgumentError, "agent not found: #{id}" unless File.file?(path)

        JSON.parse(File.read(path))
      end

      def read_status(record)
        path = record.fetch("status_path")
        return nil unless File.file?(path)

        JSON.parse(File.read(path))
      end

      def read_tail(path, max_output_bytes)
        return "" unless File.file?(path)

        size = File.size(path)
        File.open(path, "rb") do |file|
          file.seek([size - max_output_bytes, 0].max)
          content = file.read.to_s
          content = "[truncated to last #{max_output_bytes} bytes]\n#{content}" if size > max_output_bytes
          content.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\uFFFD")
        end
      end

      def status_for(status)
        exit_status(status).zero? ? "ok" : "error"
      end

      def error_for(status)
        return nil if exit_status(status).zero?

        {
          "code" => "exit_status",
          "class" => nil,
          "message" => "agent exited with status #{exit_status(status)}",
          "details" => status
        }
      end

      def exit_status(status)
        return 0 unless status

        value = status["exit_status"]
        value.nil? ? 0 : value.to_i
      end

      def compact_record(record)
        record.slice("id", "name", "cwd", "tmux_session", "started_at", "running", "status_record")
      end

      def required_arg(args, key, action)
        value = args[key]
        raise ArgumentError, "#{key} is required for agent #{action}" if value.to_s.empty?

        value
      end

      def agent_home
        File.join(ENV.fetch("KREATOR_HOME", File.expand_path("~/.kreator")), "agents")
      end

      def signal_check(signal)
        return unless signal.respond_to?(:aborted?) && signal.aborted?

        raise ToolCancellationError
      end
    end
  end
end
