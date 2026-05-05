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
        command, timeout, max_output_bytes = bash_arguments(args, context)
        prepare_bash_call(context, command, timeout, signal)
        execution = run_bash_command(context, command, signal, timeout)

        output, truncated = truncate_output(execution.fetch(:stdout), execution.fetch(:stderr), max_output_bytes)
        ToolResult.new(
          tool_call_id: "",
          name: name,
          content: output,
          status: bash_status(execution),
          metadata: bash_metadata(execution, truncated),
          error: bash_error(execution.fetch(:status), execution.fetch(:timed_out), execution.fetch(:cancelled))
        )
      end

      private

      def bash_arguments(args, context)
        [
          args.fetch("command"),
          args.fetch("timeout", context.bash_timeout || @default_timeout),
          args.fetch("max_output_bytes", DEFAULT_MAX_OUTPUT_BYTES)
        ]
      end

      def prepare_bash_call(context, command, timeout, signal)
        context.ensure_bash_allowed!(command)
        context.approve!(
          action: :bash,
          target: command,
          details: { "cwd" => context.cwd, "timeout" => timeout }
        )
        context.ensure_not_cancelled!(signal)
      end

      def run_bash_command(context, command, signal, timeout)
        execution = empty_execution

        Open3.popen3(context.bash_env, command, chdir: context.cwd) do |stdin, out, err, wait_thread|
          stdin.close
          readers = output_readers(out, err, execution)

          begin
            monitor_process(wait_thread, signal, timeout, execution)
            execution[:status] = wait_thread.value
          ensure
            readers.each(&:join)
          end
        end

        execution
      end

      def empty_execution
        {
          stdout: +"",
          stderr: +"",
          status: nil,
          timed_out: false,
          cancelled: false
        }
      end

      def output_readers(out, err, execution)
        [
          Thread.new { out.each_line { |line| execution[:stdout] << line } },
          Thread.new { err.each_line { |line| execution[:stderr] << line } }
        ]
      end

      def monitor_process(wait_thread, signal, timeout, execution)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        loop do
          break unless wait_thread.alive?

          if signal.respond_to?(:aborted?) && signal.aborted?
            execution[:cancelled] = true
            terminate_process(wait_thread)
            break
          end

          if process_timed_out?(started_at, timeout)
            execution[:timed_out] = true
            terminate_process(wait_thread)
            break
          end

          sleep 0.05
        end
      end

      def process_timed_out?(started_at, timeout)
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at > timeout
      end

      def bash_status(execution)
        status = execution.fetch(:status)
        execution.fetch(:timed_out) || execution.fetch(:cancelled) || !status.success? ? "error" : "ok"
      end

      def bash_metadata(execution, truncated)
        {
          "exit_status" => execution.fetch(:status)&.exitstatus,
          "timed_out" => execution.fetch(:timed_out),
          "cancelled" => execution.fetch(:cancelled),
          "truncated" => truncated
        }
      end

      def terminate_process(wait_thread)
        Process.kill("TERM", wait_thread.pid)
        Timeout.timeout(2) { wait_thread.value }
      rescue Timeout::Error
        Process.kill("KILL", wait_thread.pid)
      rescue Errno::ESRCH
        nil
      end

      def bash_error(status, timed_out, cancelled)
        return nil if !timed_out && !cancelled && status&.success?

        code = if cancelled
                 "cancelled"
               elsif timed_out
                 "timeout"
               else
                 "exit_status"
               end

        {
          "code" => code,
          "class" => nil,
          "message" => "bash command #{code.tr('_', ' ')}",
          "details" => { "exit_status" => status&.exitstatus }
        }
      end

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
