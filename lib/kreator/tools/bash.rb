# frozen_string_literal: true

require "open3"
require "timeout"

module Kreator
  module Tools
    class Bash
      DEFAULT_MAX_OUTPUT_BYTES = 20_000

      def initialize(default_timeout: ToolContext::DEFAULT_BASH_TIMEOUT)
        @default_timeout = Integer(default_timeout)
      end

      def name
        "bash"
      end

      def description
        "Run a shell command in the current workspace with timeout and output truncation."
      end

      def schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["command"],
          "properties" => {
            "command" => { "type" => "string", "minLength" => 1 },
            "timeout" => { "type" => "integer", "minimum" => 1 },
            "max_output_bytes" => { "type" => "integer", "minimum" => 1 }
          }
        }
      end

      def call(args:, context:, signal:)
        command = args.fetch("command")
        timeout = args.fetch("timeout", context.bash_timeout || @default_timeout)
        max_output_bytes = args.fetch("max_output_bytes", DEFAULT_MAX_OUTPUT_BYTES)

        stdout = +""
        stderr = +""
        status = nil
        timed_out = false

        Open3.popen3(command, chdir: context.cwd) do |stdin, out, err, wait_thread|
          stdin.close
          readers = [
            Thread.new { out.each_line { |line| stdout << line } },
            Thread.new { err.each_line { |line| stderr << line } }
          ]

          begin
            Timeout.timeout(timeout) { status = wait_thread.value }
          rescue Timeout::Error
            timed_out = true
            Process.kill("TERM", wait_thread.pid)
            begin
              Timeout.timeout(2) { status = wait_thread.value }
            rescue Timeout::Error
              Process.kill("KILL", wait_thread.pid)
              status = wait_thread.value
            end
          ensure
            readers.each(&:join)
          end
        end

        output, truncated = truncate_output(stdout, stderr, max_output_bytes)
        ToolResult.new(
          tool_call_id: "",
          name: name,
          content: output,
          status: timed_out || !status.success? ? "error" : "ok",
          metadata: {
            "exit_status" => status&.exitstatus,
            "timed_out" => timed_out,
            "truncated" => truncated
          }
        )
      end

      private

      def truncate_output(stdout, stderr, max_output_bytes)
        output = +""
        output << "stdout:\n#{stdout}" unless stdout.empty?
        output << "\n" unless output.empty? || stderr.empty?
        output << "stderr:\n#{stderr}" unless stderr.empty?
        output = "(no output)" if output.empty?

        return [output, false] if output.bytesize <= max_output_bytes

        ["#{output.byteslice(0, max_output_bytes)}\n[truncated after #{max_output_bytes} bytes]", true]
      end
    end
  end
end
