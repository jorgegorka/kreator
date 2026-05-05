# frozen_string_literal: true

require "stringio"
require "test_helper"
require "tmpdir"

class CLITest < Minitest::Test
  class FakeProvider
    attr_reader :received

    def stream(messages:, tools:, system_prompt:, model:, signal:)
      @received = { messages: messages, tools: tools, system_prompt: system_prompt, model: model, signal: signal }
      yield type: "message_start", role: "assistant"
      yield type: "message_delta", delta: "#{model}: #{messages.last.content}"
      yield type: "message_end"
    end
  end

  def test_print_mode_streams_assistant_text
    stdout = StringIO.new
    stderr = StringIO.new

    status = Kreator::CLI.new(
      ["--no-session", "--model", "fake-model", "Hello"],
      stdout: stdout,
      stderr: stderr,
      provider_builder: ->(_name) { FakeProvider.new }
    ).run

    assert_equal 0, status
    assert_equal "fake-model: Hello\n", stdout.string
    assert_equal "", stderr.string
  end

  def test_no_tools_disables_tool_registry
    stdout = StringIO.new
    stderr = StringIO.new
    provider = FakeProvider.new

    status = Kreator::CLI.new(
      ["--no-session", "--no-tools", "Hello"],
      stdout: stdout,
      stderr: stderr,
      provider_builder: ->(_name) { provider }
    ).run

    assert_equal 0, status
    assert_empty provider.received.fetch(:tools)
  end

  def test_tools_selects_enabled_tool_names
    stdout = StringIO.new
    stderr = StringIO.new
    provider = FakeProvider.new

    status = Kreator::CLI.new(
      ["--no-session", "--tools", "read,bash", "Hello"],
      stdout: stdout,
      stderr: stderr,
      provider_builder: ->(_name) { provider }
    ).run

    assert_equal 0, status
    assert_equal %w[read bash], provider.received.fetch(:tools).map(&:name)
  end

  def test_default_session_persists_turn
    Dir.mktmpdir do |dir|
      stdout = StringIO.new
      stderr = StringIO.new

      status = Kreator::CLI.new(
        ["--session-dir", dir, "Hello"],
        stdout: stdout,
        stderr: stderr,
        provider_builder: ->(_name) { FakeProvider.new }
      ).run

      assert_equal 0, status
      session_path = Dir.glob(File.join(dir, "*", "*.jsonl")).first
      session = Kreator::SessionManager.new(session_dir: dir).open(path: session_path)
      assert_equal %w[user assistant], session.messages.map(&:role)
      assert_equal "Hello", session.messages.first.content
    end
  end

  def test_continue_uses_recent_session_messages
    Dir.mktmpdir do |dir|
      first_provider = FakeProvider.new
      second_provider = FakeProvider.new

      Kreator::CLI.new(
        ["--session-dir", dir, "Hello"],
        stdout: StringIO.new,
        stderr: StringIO.new,
        provider_builder: ->(_name) { first_provider }
      ).run

      status = Kreator::CLI.new(
        ["--session-dir", dir, "--continue", "Again"],
        stdout: StringIO.new,
        stderr: StringIO.new,
        provider_builder: ->(_name) { second_provider }
      ).run

      assert_equal 0, status
      assert_equal %w[user assistant user], second_provider.received.fetch(:messages).map(&:role)
      assert_equal "Again", second_provider.received.fetch(:messages).last.content
      session_path = Dir.glob(File.join(dir, "*", "*.jsonl")).first
      session = Kreator::SessionManager.new(session_dir: dir).open(path: session_path)
      assert_equal %w[user assistant user assistant], session.messages.map(&:role)
    end
  end

  def test_json_mode_outputs_structured_response_without_streaming_text
    stdout = StringIO.new
    stderr = StringIO.new

    status = Kreator::CLI.new(
      ["--no-session", "--json", "--model", "fake-model", "Hello"],
      stdout: stdout,
      stderr: stderr,
      provider_builder: ->(_name) { FakeProvider.new }
    ).run

    payload = JSON.parse(stdout.string)
    assert_equal 0, status
    assert_equal true, payload.fetch("ok")
    assert_equal "assistant", payload.fetch("message").fetch("role")
    assert_equal "fake-model: Hello", payload.fetch("message").fetch("content")
    assert_equal %w[user assistant], payload.fetch("messages").map { |message| message.fetch("role") }
    assert_nil payload.fetch("usage")
    assert_equal "", stderr.string
  end

  def test_json_mode_outputs_structured_errors
    stdout = StringIO.new
    stderr = StringIO.new

    status = Kreator::CLI.new(
      ["--json", "--session", "missing", "Hello"],
      stdout: stdout,
      stderr: stderr,
      provider_builder: ->(_name) { FakeProvider.new }
    ).run

    payload = JSON.parse(stdout.string)
    assert_equal 1, status
    assert_equal false, payload.fetch("ok")
    assert_includes payload.fetch("error").fetch("message"), "session not found"
    assert_equal "", stderr.string
  end

  def test_rpc_prompt_state_and_messages
    Dir.mktmpdir do |dir|
      stdin = StringIO.new(
        [
          JSON.generate("id" => "1", "command" => "get_state"),
          JSON.generate("id" => "2", "command" => "prompt", "prompt" => "Hello"),
          JSON.generate("id" => "3", "command" => "get_messages")
        ].join("\n")
      )
      stdout = StringIO.new

      status = Kreator::CLI.new(
        ["--rpc", "--session-dir", dir],
        stdin: stdin,
        stdout: stdout,
        stderr: StringIO.new,
        provider_builder: ->(_name) { FakeProvider.new }
      ).run

      lines = stdout.string.lines.map { |line| JSON.parse(line) }
      responses = lines.select { |line| line.fetch("type") == "response" }
      events = lines.select { |line| line.fetch("type") == "event" }
      assert_equal 0, status
      assert_equal %w[1 2 3], responses.map { |line| line.fetch("id") }
      assert_equal true, responses[1].fetch("ok")
      assert_equal "assistant", responses[1].fetch("message").fetch("role")
      assert_equal %w[user assistant], responses[2].fetch("messages").map { |message| message.fetch("role") }
      assert_includes events.map { |line| line.fetch("event").fetch("type") }, "message_delta"
    end
  end

  def test_rpc_set_model_affects_next_prompt
    stdin = StringIO.new(
      [
        JSON.generate("id" => "1", "command" => "set_model", "model" => "next-model"),
        JSON.generate("id" => "2", "command" => "prompt", "prompt" => "Hello")
      ].join("\n")
    )
    stdout = StringIO.new

    status = Kreator::CLI.new(
      ["--rpc", "--no-session"],
      stdin: stdin,
      stdout: stdout,
      stderr: StringIO.new,
      provider_builder: ->(_name) { FakeProvider.new }
    ).run

    responses = stdout.string.lines.map { |line| JSON.parse(line) }.select { |line| line.fetch("type") == "response" }
    assert_equal 0, status
    assert_equal "next-model", responses.first.fetch("state").fetch("model")
    assert_equal "next-model: Hello", responses.last.fetch("message").fetch("content")
  end

  def test_missing_prompt_prints_usage
    stdout = StringIO.new
    stderr = StringIO.new

    status = Kreator::CLI.new([], stdin: StringIO.new, stdout: stdout, stderr: stderr).run

    assert_equal 1, status
    assert_includes stderr.string, "Usage: kreator"
  end
end
