# frozen_string_literal: true

require "stringio"
require "test_helper"
require "tmpdir"

class InteractiveCLITest < Minitest::Test
  class FakeProvider
    def stream(messages:, tools:, system_prompt:, model:, signal:)
      yield type: "message_start", role: "assistant"
      yield type: "message_delta", delta: "#{model}: #{messages.last.content}"
      yield type: "message_end"
    end
  end

  def test_line_mode_handles_help_and_exit_without_charm
    stdout = StringIO.new
    status = interactive(stdin: StringIO.new("/help\n/exit\n"), stdout: stdout).run

    assert_equal 0, status
    assert_includes stdout.string, "Kreator interactive mode"
    assert_includes stdout.string, "Commands: /new, /resume, /model [name], /session, /help, /exit"
  end

  def test_submit_prompt_runs_agent_and_persists_messages
    Dir.mktmpdir do |dir|
      manager = Kreator::SessionManager.new(session_dir: dir)
      session = manager.create(cwd: Dir.pwd)
      app = interactive(stdin: StringIO.new, stdout: StringIO.new, session_manager: manager, session: session)

      entries = app.submit("Hello")

      assert_includes entries.join("\n"), "You: Hello"
      assert_includes entries.join("\n"), "Kreator: fake-model: Hello"
      assert_equal %w[user assistant], session.messages.map(&:role)
    end
  end

  def test_submit_model_command_updates_model
    app = interactive(stdin: StringIO.new, stdout: StringIO.new)

    assert_equal ["system: Model set to next-model"], app.submit("/model next-model")
    assert_equal ["system: Current model: next-model. Press Ctrl+m for model picker."], app.submit("/model")
  end

  def test_available_models_include_current_model
    app = interactive(stdin: StringIO.new, stdout: StringIO.new)

    assert_includes app.available_models, "fake-model"
  end

  def test_resume_session_by_path
    Dir.mktmpdir do |dir|
      manager = Kreator::SessionManager.new(session_dir: dir)
      session = manager.create(cwd: Dir.pwd)
      app = interactive(stdin: StringIO.new, stdout: StringIO.new, session_manager: manager)

      message = app.resume_session(session.path)

      assert_includes message, "Resumed session #{session.id}"
      assert_includes app.submit("/session").first, session.id
    end
  end

  def test_transcript_entry_collapses_and_expands_tool_output
    entry = Kreator::InteractiveCLI::TranscriptEntry.new(
      role: "tool",
      title: "tool: read ok",
      body: "file contents",
      collapsible: true
    )

    assert_equal "[+] tool: read ok", entry.to_s
    entry.toggle
    assert_equal "[-] tool: read ok\nfile contents", entry.to_s
  end

  private

  def interactive(stdin:, stdout:, session_manager: Kreator::SessionManager.new(session_dir: Dir.mktmpdir), session: nil)
    Kreator::InteractiveCLI.new(
      provider_builder: ->(_name) { FakeProvider.new },
      provider_name: "fake",
      model: "fake-model",
      tools: Kreator::ToolRegistry.new,
      context: Kreator::ToolContext.new,
      session_manager: session_manager,
      session: session,
      stdin: stdin,
      stdout: stdout,
      stderr: StringIO.new
    )
  end
end
