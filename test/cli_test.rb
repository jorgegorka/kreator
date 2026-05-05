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

  def test_missing_prompt_prints_usage
    stdout = StringIO.new
    stderr = StringIO.new

    status = Kreator::CLI.new([], stdout: stdout, stderr: stderr).run

    assert_equal 1, status
    assert_includes stderr.string, "Usage: kreator"
  end
end
