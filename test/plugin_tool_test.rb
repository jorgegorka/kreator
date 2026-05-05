# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "test_helper"
require "tmpdir"

class PluginToolTest < Minitest::Test
  def test_plugin_tool_loader_exposes_namespaced_tools
    Dir.mktmpdir do |dir|
      plugin = write_plugin(dir, plugin_name: "echo")

      tools = Kreator::PluginToolLoader.new.load_tools([plugin])

      assert_equal ["echo.echo"], tools.map(&:name)
      assert_equal "Echo input", tools.first.description
    end
  end

  def test_plugin_tool_execution_requires_plugin_approval_by_default
    Dir.mktmpdir do |dir|
      plugin = write_plugin(dir, plugin_name: "echo")
      tool = Kreator::PluginToolLoader.new.load_tools([plugin]).first
      call = Kreator::ToolCall.new(id: "call_1", name: "echo.echo", arguments: { "text" => "hello" })
      registry = Kreator::ToolRegistry.new([tool])

      result = registry.call(call, context: Kreator::ToolContext.new(cwd: dir))

      assert_equal "error", result.status
      assert_equal "permission_denied", result.error.fetch("code")
    end
  end

  def test_plugin_tool_executes_when_approved
    Dir.mktmpdir do |dir|
      plugin = write_plugin(dir, plugin_name: "echo")
      tool = Kreator::PluginToolLoader.new.load_tools([plugin]).first
      call = Kreator::ToolCall.new(id: "call_1", name: "echo.echo", arguments: { "text" => "hello" })
      context = Kreator::ToolContext.new(cwd: dir, plugin_approval_policy: "auto")

      result = Kreator::ToolRegistry.new([tool]).call(call, context: context)

      assert_equal "ok", result.status
      assert_equal "echo: hello", result.content
      assert_equal "echo", result.metadata.fetch("plugin")
    end
  end

  def test_duplicate_plugin_tool_names_fail
    Dir.mktmpdir do |dir|
      first = write_plugin(File.join(dir, "first"), plugin_name: "same")
      second = write_plugin(File.join(dir, "second"), plugin_name: "same")

      assert_raises(ArgumentError) do
        Kreator::PluginToolLoader.new.load_tools([first, second])
      end
    end
  end

  def test_invalid_tool_class_is_reported_by_validation
    Dir.mktmpdir do |dir|
      plugin_dir = File.join(dir, "broken")
      FileUtils.mkdir_p(File.join(plugin_dir, "tools"))
      File.write(File.join(plugin_dir, "plugin.json"), JSON.generate("name" => "broken", "tools" => [{ "path" => "tools/missing.rb", "class" => "Missing" }]))
      plugin = Kreator::Plugin.new(path: plugin_dir, manifest: JSON.parse(File.read(File.join(plugin_dir, "plugin.json"))))

      errors = Kreator::PluginToolLoader.new.validate(plugin)

      refute_empty errors
      assert_includes errors.first, "plugin file not found"
    end
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
        "tools" => [{ "path" => "tools/echo.rb", "class" => "KreatorPluginTests::#{class_name}" }]
      )
    )
    File.write(
      File.join(plugin_dir, "tools", "echo.rb"),
      <<~RUBY
        module KreatorPluginTests
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
