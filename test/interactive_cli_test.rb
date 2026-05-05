# frozen_string_literal: true

require "stringio"
require "fileutils"
require "test_helper"
require "tmpdir"

class InteractiveCLITest < Minitest::Test
  class FakeProvider
    def stream(messages:, model:, **_options)
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
    assert_includes stdout.string, "/prompts"
    assert_includes stdout.string, "/plugins"
    assert_includes stdout.string, "/compact"
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

  def test_fork_command_switches_to_child_session
    Dir.mktmpdir do |dir|
      manager = Kreator::SessionManager.new(session_dir: dir)
      session = manager.create(cwd: Dir.pwd)
      session.append_message(Kreator::Message.user("first"))
      session.append_message(Kreator::Message.assistant("second"))
      app = interactive(stdin: StringIO.new, stdout: StringIO.new, session_manager: manager, session: session)

      message = app.submit("/fork 0").first

      assert_includes message, "Forked session"
      assert_equal 1, manager.branches(parent_id: session.id).length
      assert_includes app.submit("/session").first, manager.branches(parent_id: session.id).first.fetch("id")
    end
  end

  def test_prompt_template_command_runs_materialized_prompt
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".kreator", "prompts"))
      File.write(File.join(dir, ".kreator", "prompts", "wrap.md"), "Wrapped: {{prompt}}")
      resources = Kreator::Resources.new(cwd: dir, home_dir: File.join(dir, "home"))
      app = interactive(stdin: StringIO.new, stdout: StringIO.new, resources: resources)

      entries = app.submit("/prompt wrap hello")

      assert_includes entries.join("\n"), "You: Wrapped: hello"
      assert_includes entries.join("\n"), "Kreator: fake-model: Wrapped: hello"
    end
  end

  def test_plugins_command_lists_enabled_plugins
    Dir.mktmpdir do |dir|
      plugin_dir = File.join(dir, "home", "plugins", "reviewer")
      FileUtils.mkdir_p(plugin_dir)
      File.write(File.join(plugin_dir, "plugin.json"), JSON.generate("name" => "reviewer"))
      resources = Kreator::Resources.new(cwd: dir, home_dir: File.join(dir, "home"))
      app = interactive(stdin: StringIO.new, stdout: StringIO.new, resources: resources)

      assert_equal ["system: Plugins: reviewer"], app.submit("/plugins")
      assert_equal ["system: Plugins: reviewer"], app.submit("/plugin list")
      assert_equal ["system: Plugin reviewer ok"], app.submit("/plugin validate reviewer")
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

  def interactive(
    stdin:,
    stdout:,
    session_manager: Kreator::SessionManager.new(session_dir: Dir.mktmpdir),
    session: nil,
    resources: Kreator::Resources.new
  )
    Kreator::InteractiveCLI.new(
      provider_builder: ->(_name) { FakeProvider.new },
      provider_name: "fake",
      model: "fake-model",
      tools: Kreator::ToolRegistry.new,
      context: Kreator::ToolContext.new,
      session_manager: session_manager,
      session: session,
      resources: resources,
      stdin: stdin,
      stdout: stdout,
      stderr: StringIO.new
    )
  end
end
