# frozen_string_literal: true

require "stringio"
require "fileutils"
require "bubbletea"
require "bubbles"
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

  class FakeRuntime
    attr_reader :prompts

    def initialize
      @prompts = []
    end

    def welcome_panel = "welcome"

    def transcript = []

    def submit(prompt)
      @prompts << prompt
      ["Kreator: #{prompt}"]
    end

    def context_meter
      { window: 100_000, used: 25_000, available: 75_000 }
    end

    def available_autocomplete_items
      [
        { value: "/help", label: "/help", description: "show commands", kind: "command" },
        { value: "/model", label: "/model", description: "show or change model", kind: "command" },
        { value: "$rails", label: "skill: rails", description: "load skill context", kind: "skill" }
      ]
    end
  end

  def test_line_mode_handles_help_and_exit_without_charm
    stdout = StringIO.new
    status = interactive(stdin: StringIO.new("/help\n/exit\n"), stdout: stdout).run

    assert_equal 0, status
    assert_includes stdout.string, ">_ Kreator (v#{Kreator::VERSION})"
    assert_includes stdout.string, "model:     fake-model   /model to change"
    assert_includes stdout.string, "directory:"
    assert_includes stdout.string, "Type /help for commands, /exit to quit."
    assert_includes stdout.string, "/prompts"
    assert_includes stdout.string, "/plugins"
    assert_includes stdout.string, "/compact"
  end

  def test_welcome_panel_uses_home_relative_directory
    app = interactive(stdin: StringIO.new, stdout: StringIO.new)

    assert_includes app.welcome_panel, "directory: #{Dir.pwd.sub(%r{\A#{Regexp.escape(Dir.home)}(?=/)}, '~')}"
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

  def test_submit_exit_command_exits_interactive_loop
    app = interactive(stdin: StringIO.new, stdout: StringIO.new)

    exited = catch(:exit_interactive) do
      app.submit("/exit")
      false
    end

    assert_nil exited
  end

  def test_available_models_include_current_model
    app = interactive(stdin: StringIO.new, stdout: StringIO.new)

    assert_includes app.available_models, "fake-model"
  end

  def test_available_models_include_current_openai_models
    app = interactive(stdin: StringIO.new, stdout: StringIO.new, provider_name: "openai")

    assert_includes app.available_models, "gpt-5.2"
    assert_includes app.available_models, "gpt-5-mini"
    refute_includes app.available_models, "gpt-4o-mini"
  end

  def test_available_models_include_current_anthropic_models
    app = interactive(stdin: StringIO.new, stdout: StringIO.new, provider_name: "anthropic")

    assert_includes app.available_models, "claude-sonnet-4-20250514"
    assert_includes app.available_models, "claude-opus-4-1-20250805"
    refute_includes app.available_models, "claude-3-5-sonnet-latest"
  end

  def test_available_models_include_current_openrouter_models
    app = interactive(stdin: StringIO.new, stdout: StringIO.new, provider_name: "openrouter")

    assert_includes app.available_models, "openrouter/auto"
    assert_includes app.available_models, "openai/gpt-5.2"
  end

  def test_available_autocomplete_items_include_commands_and_skills
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".kreator", "skills", "rails"))
      File.write(File.join(dir, ".kreator", "skills", "rails", "SKILL.md"), "# Rails\nUse Rails conventions.")
      resources = Kreator::Resources.new(cwd: dir, home_dir: File.join(dir, "home"))
      app = interactive(stdin: StringIO.new, stdout: StringIO.new, resources: resources)
      labels = app.available_autocomplete_items.map { |item| item.fetch(:label) }

      assert_includes labels, "/exit"
      assert_includes labels, "skill: rails"
    end
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

  def test_chat_model_enter_submits_input
    runtime = FakeRuntime.new
    model = chat_model(runtime)
    textarea(model).value = "Send this"

    model.update(key_message("enter"))

    assert_equal ["Send this"], runtime.prompts
    assert_equal "", textarea(model).value
  end

  def test_chat_model_exit_command_quits_without_submitting
    runtime = FakeRuntime.new
    model = chat_model(runtime)
    textarea(model).value = "/exit"

    _model, command = model.update(key_message("enter"))

    assert_instance_of Bubbletea::QuitCommand, command
    assert_empty runtime.prompts
  end

  def test_chat_model_alt_enter_inserts_newline
    model = chat_model
    textarea(model).value = "first line"

    model.update(key_message("alt+enter"))

    assert_equal "first line\n", textarea(model).value
  end

  def test_chat_model_ctrl_s_saves_draft_and_restores_after_submit
    runtime = FakeRuntime.new
    model = chat_model(runtime)
    textarea(model).value = "long draft"

    model.update(key_message("ctrl+s"))

    assert_equal "", textarea(model).value

    textarea(model).value = "quick note"
    model.update(key_message("enter"))

    assert_equal ["quick note"], runtime.prompts
    assert_equal "long draft", textarea(model).value
    assert_nil model.instance_variable_get(:@draft_buffer)
  end

  def test_chat_model_context_bar_shows_available_context
    model = chat_model
    textarea(model).width = 58

    assert_equal "context: [███████████████░░░░░] 75% available (75k/100k)", model.send(:context_bar)
  end

  def test_chat_model_view_places_context_bar_after_input
    model = chat_model
    textarea(model).value = "draft"

    lines = model.view.lines.map(&:chomp)

    assert(lines.any? { |line| line.include?("> draft") })
    assert_match(/\Acontext: /, lines.last)
  end

  def test_chat_model_autocomplete_shows_commands_when_slash_is_typed
    model = chat_model
    textarea(model).value = "/"

    panel = model.send(:autocomplete_panel)

    assert_includes panel, "/help"
    assert_includes panel, "/model"
    assert_includes panel, "skill: rails"
  end

  def test_chat_model_autocomplete_filters_results
    model = chat_model
    textarea(model).value = "/mod"

    panel = model.send(:autocomplete_panel)

    assert_includes panel, "/model"
    refute_includes panel, "/help"
    refute_includes panel, "skill: rails"
  end

  private

  def chat_model(runtime = FakeRuntime.new)
    Kreator::InteractiveCLI::ChatModel.new(runtime: runtime)
  end

  def textarea(model)
    model.instance_variable_get(:@textarea)
  end

  def key_message(name)
    case name
    when "enter"
      Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ENTER, name: "enter")
    when "alt+enter"
      Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ENTER, alt: true)
    when "ctrl+s"
      Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_CTRL_S, name: "ctrl+s")
    end
  end

  def interactive(
    stdin:,
    stdout:,
    **options
  )
    session_manager = options.fetch(:session_manager) { Kreator::SessionManager.new(session_dir: Dir.mktmpdir) }
    Kreator::InteractiveCLI.new(
      provider_builder: ->(_name) { FakeProvider.new },
      provider_name: options.fetch(:provider_name, "fake"),
      model: "fake-model",
      tools: Kreator::ToolRegistry.new,
      context: Kreator::ToolContext.new,
      session_manager: session_manager,
      session: options[:session],
      resources: options.fetch(:resources) { Kreator::Resources.new },
      stdin: stdin,
      stdout: stdout,
      stderr: StringIO.new
    )
  end
end
