# frozen_string_literal: true

require "stringio"
require "fileutils"
require "securerandom"
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

  class PluginToolProvider
    attr_reader :received

    def initialize
      @requests = []
    end

    def stream(messages:, tools:, system_prompt:, model:, signal:)
      @received = { messages: messages, tools: tools, system_prompt: system_prompt, model: model, signal: signal }
      yield type: "message_start", role: "assistant"
      if messages.any? { |message| message.role == "tool" }
        yield type: "message_delta", delta: "result: #{messages.last.content}"
        yield type: "message_end"
      else
        yield(
          type: "message_end",
          tool_calls: [
            Kreator::ToolCall.new(id: "call_1", name: "echo.echo", arguments: { "text" => "hello" })
          ]
        )
      end
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
    assert payload.fetch("ok")
    assert_equal "assistant", payload.fetch("message").fetch("role")
    assert_equal "fake-model: Hello", payload.fetch("message").fetch("content")
    assert_equal(%w[user assistant], payload.fetch("messages").map { |message| message.fetch("role") })
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
    refute payload.fetch("ok")
    assert_includes payload.fetch("error").fetch("message"), "session not found"
    assert_equal "", stderr.string
  end

  def test_resources_are_added_to_system_prompt_and_prompt_template_is_applied
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "AGENTS.md"), "Always run focused tests.")
      FileUtils.mkdir_p(File.join(dir, ".kreator", "prompts"))
      File.write(File.join(dir, ".kreator", "prompts", "review.md"), "Review template: {{prompt}}")
      FileUtils.mkdir_p(File.join(dir, ".kreator", "skills", "rails"))
      File.write(File.join(dir, ".kreator", "skills", "rails", "SKILL.md"), "# Rails\nPrefer Rails conventions.")
      provider = FakeProvider.new

      status = Dir.chdir(dir) do
        Kreator::CLI.new(
          ["--no-session", "--resource-home", File.join(dir, "home"), "--prompt-template", "review", "Use $rails"],
          stdout: StringIO.new,
          stderr: StringIO.new,
          provider_builder: ->(_name) { provider }
        ).run
      end

      assert_equal 0, status
      assert_equal "Review template: Use $rails", provider.received.fetch(:messages).last.content
      assert_includes provider.received.fetch(:system_prompt), "Always run focused tests."
      assert_includes provider.received.fetch(:system_prompt), "Prefer Rails conventions."
    end
  end

  def test_plugin_resources_can_be_used_and_disabled
    Dir.mktmpdir do |dir|
      plugin_dir = File.join(dir, "home", "plugins", "reviewer")
      FileUtils.mkdir_p(File.join(plugin_dir, "prompts"))
      File.write(File.join(plugin_dir, "plugin.json"), JSON.generate("name" => "reviewer"))
      File.write(File.join(plugin_dir, "instructions.md"), "Plugin says be strict.")
      File.write(File.join(plugin_dir, "prompts", "plugin-review.md"), "Plugin template: {{prompt}}")
      provider = FakeProvider.new

      status = Dir.chdir(dir) do
        Kreator::CLI.new(
          ["--no-session", "--resource-home", File.join(dir, "home"), "--prompt-template", "plugin-review", "Hello"],
          stdout: StringIO.new,
          stderr: StringIO.new,
          provider_builder: ->(_name) { provider }
        ).run
      end

      assert_equal 0, status
      assert_equal "Plugin template: Hello", provider.received.fetch(:messages).last.content
      assert_includes provider.received.fetch(:system_prompt), "Plugin says be strict."

      stdout = StringIO.new
      stderr = StringIO.new
      disabled_status = Dir.chdir(dir) do
        Kreator::CLI.new(
          ["--no-session", "--resource-home", File.join(dir, "home"), "--no-plugins", "--prompt-template", "plugin-review", "Hello"],
          stdout: stdout,
          stderr: stderr,
          provider_builder: ->(_name) { FakeProvider.new }
        ).run
      end

      assert_equal 1, disabled_status
      assert_includes stderr.string, "prompt template not found"
    end
  end

  def test_plugin_tools_are_registered_and_can_be_selected
    Dir.mktmpdir do |dir|
      write_plugin(File.join(dir, "home", "plugins"), plugin_name: "echo")
      provider = FakeProvider.new

      status = Kreator::CLI.new(
        ["--no-session", "--resource-home", File.join(dir, "home"), "--tools", "echo.echo", "Hello"],
        stdout: StringIO.new,
        stderr: StringIO.new,
        provider_builder: ->(_name) { provider }
      ).run

      assert_equal 0, status
      assert_equal ["echo.echo"], provider.received.fetch(:tools).map(&:name)
    end
  end

  def test_no_plugins_disables_plugin_tools
    Dir.mktmpdir do |dir|
      write_plugin(File.join(dir, "home", "plugins"), plugin_name: "echo")
      provider = FakeProvider.new

      status = Kreator::CLI.new(
        ["--no-session", "--resource-home", File.join(dir, "home"), "--no-plugins", "Hello"],
        stdout: StringIO.new,
        stderr: StringIO.new,
        provider_builder: ->(_name) { provider }
      ).run

      assert_equal 0, status
      refute_includes provider.received.fetch(:tools).map(&:name), "echo.echo"
    end
  end

  def test_plugin_tool_execution_prompts_for_approval
    Dir.mktmpdir do |dir|
      write_plugin(File.join(dir, "home", "plugins"), plugin_name: "echo")
      stdout = StringIO.new
      stderr = StringIO.new

      status = Kreator::CLI.new(
        ["--no-session", "--resource-home", File.join(dir, "home"), "Use tool"],
        stdin: StringIO.new("yes\n"),
        stdout: stdout,
        stderr: stderr,
        provider_builder: ->(_name) { PluginToolProvider.new }
      ).run

      assert_equal 0, status
      assert_includes stdout.string, "result: echo: hello"
      assert_includes stderr.string, "Plugin tool: echo echo.echo"
    end
  end

  def test_plugin_lifecycle_commands
    Dir.mktmpdir do |dir|
      source = write_plugin(File.join(dir, "source"), plugin_name: "echo").path
      home = File.join(dir, "home")

      install_stdout = StringIO.new
      install_status = Kreator::CLI.new(
        ["--resource-home", home, "plugin", "install", source, "--name", "installed"],
        stdout: install_stdout,
        stderr: StringIO.new,
        provider_builder: ->(_name) { FakeProvider.new }
      ).run

      list_stdout = StringIO.new
      list_status = Kreator::CLI.new(
        ["--resource-home", home, "plugin", "list"],
        stdout: list_stdout,
        stderr: StringIO.new,
        provider_builder: ->(_name) { FakeProvider.new }
      ).run

      validate_stdout = StringIO.new
      validate_status = Kreator::CLI.new(
        ["--resource-home", home, "plugin", "validate", "installed"],
        stdout: validate_stdout,
        stderr: StringIO.new,
        provider_builder: ->(_name) { FakeProvider.new }
      ).run

      remove_stdout = StringIO.new
      remove_status = Kreator::CLI.new(
        ["--resource-home", home, "plugin", "remove", "installed"],
        stdout: remove_stdout,
        stderr: StringIO.new,
        provider_builder: ->(_name) { FakeProvider.new }
      ).run

      assert_equal 0, install_status
      assert_includes install_stdout.string, "installed"
      assert_equal 0, list_status
      assert_includes list_stdout.string, "installed.echo"
      assert_equal 0, validate_status
      assert_includes validate_stdout.string, "Validation ok"
      assert_equal 0, remove_status
      assert_includes remove_stdout.string, "Removed plugin installed"
    end
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
      assert_equal(%w[1 2 3], responses.map { |line| line.fetch("id") })
      assert responses[1].fetch("ok")
      assert_equal "assistant", responses[1].fetch("message").fetch("role")
      assert_equal(%w[user assistant], responses[2].fetch("messages").map { |message| message.fetch("role") })
      assert_includes events.map { |line| line.fetch("event").fetch("type") }, "message_delta"
    end
  end

  def test_rpc_get_resources_includes_plugins
    Dir.mktmpdir do |dir|
      plugin_dir = File.join(dir, "home", "plugins", "reviewer")
      FileUtils.mkdir_p(plugin_dir)
      File.write(File.join(plugin_dir, "plugin.json"), JSON.generate("name" => "reviewer"))
      stdin = StringIO.new(JSON.generate("id" => "1", "command" => "get_resources"))
      stdout = StringIO.new

      status = Dir.chdir(dir) do
        Kreator::CLI.new(
          ["--rpc", "--no-session", "--resource-home", File.join(dir, "home")],
          stdin: stdin,
          stdout: stdout,
          stderr: StringIO.new,
          provider_builder: ->(_name) { FakeProvider.new }
        ).run
      end

      payload = JSON.parse(stdout.string)

      assert_equal 0, status
      assert_equal(["reviewer"], payload.fetch("resources").fetch("plugins").map { |plugin| plugin.fetch("name") })
    end
  end

  def test_rpc_plugin_lifecycle_commands
    Dir.mktmpdir do |dir|
      source = write_plugin(File.join(dir, "source"), plugin_name: "echo").path
      home = File.join(dir, "home")
      stdin = StringIO.new(
        [
          JSON.generate("id" => "1", "command" => "plugin_install", "path" => source, "name" => "installed"),
          JSON.generate("id" => "2", "command" => "plugin_list"),
          JSON.generate("id" => "3", "command" => "plugin_validate", "plugin" => "installed"),
          JSON.generate("id" => "4", "command" => "plugin_remove", "name" => "installed")
        ].join("\n")
      )
      stdout = StringIO.new

      status = Kreator::CLI.new(
        ["--rpc", "--no-session", "--resource-home", home],
        stdin: stdin,
        stdout: stdout,
        stderr: StringIO.new,
        provider_builder: ->(_name) { FakeProvider.new }
      ).run

      responses = stdout.string.lines.map { |line| JSON.parse(line) }.select { |line| line.fetch("type") == "response" }

      assert_equal 0, status
      assert_equal(%w[1 2 3 4], responses.map { |response| response.fetch("id") })
      assert responses[0].fetch("ok")
      assert_equal(["installed"], responses[1].fetch("plugins").map { |plugin| plugin.fetch("name") })
      assert responses[2].fetch("validation").fetch("ok")
      assert_equal "installed", responses[3].fetch("removed")
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

  def test_session_management_commands
    Dir.mktmpdir do |dir|
      manager = Kreator::SessionManager.new(session_dir: dir)
      session = manager.create(cwd: Dir.pwd)
      session.append_message(Kreator::Message.user("searchable text"))

      label_stdout = StringIO.new
      label_status = Kreator::CLI.new(
        ["--session-dir", dir, "--session", session.id, "--label-session", "work"],
        stdout: label_stdout,
        stderr: StringIO.new,
        provider_builder: ->(_name) { FakeProvider.new }
      ).run

      search_stdout = StringIO.new
      search_status = Kreator::CLI.new(
        ["--session-dir", dir, "--search-sessions", "searchable"],
        stdout: search_stdout,
        stderr: StringIO.new,
        provider_builder: ->(_name) { FakeProvider.new }
      ).run

      export_stdout = StringIO.new
      export_status = Kreator::CLI.new(
        ["--session-dir", dir, "--session", session.id, "--export-session", "plain"],
        stdout: export_stdout,
        stderr: StringIO.new,
        provider_builder: ->(_name) { FakeProvider.new }
      ).run

      assert_equal 0, label_status
      assert_includes label_stdout.string, "work"
      assert_equal 0, search_status
      assert_includes search_stdout.string, session.id
      assert_equal 0, export_status
      assert_includes export_stdout.string, "searchable text"
    end
  end

  def test_missing_prompt_prints_usage
    stdout = StringIO.new
    stderr = StringIO.new

    status = Kreator::CLI.new([], stdin: StringIO.new, stdout: stdout, stderr: stderr).run

    assert_equal 1, status
    assert_includes stderr.string, "Usage: kreator"
  end

  private

  def write_plugin(root, plugin_name:)
    class_name = "Echo#{SecureRandom.hex(4)}"
    plugin_dir = File.join(root, plugin_name)
    FileUtils.mkdir_p(File.join(plugin_dir, "tools"))
    File.write(
      File.join(plugin_dir, "plugin.json"),
      JSON.generate(
        "name" => plugin_name,
        "tools" => [{ "path" => "tools/echo.rb", "class" => "KreatorCliPluginTests::#{class_name}" }]
      )
    )
    File.write(
      File.join(plugin_dir, "tools", "echo.rb"),
      <<~RUBY
        module KreatorCliPluginTests
          class #{class_name} < Kreator::PluginTool
            tool_name "echo"
            description "Echo input"
            schema(
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["text"],
              "properties" => {
                "text" => { "type" => "string" }
              }
            )

            def call(args:, context:, signal:)
              Kreator::ToolResult.new(tool_call_id: "", name: "", content: "echo: \#{args.fetch("text")}")
            end
          end
        end
      RUBY
    )
    Kreator::Plugin.new(path: plugin_dir, manifest: JSON.parse(File.read(File.join(plugin_dir, "plugin.json"))))
  end
end
