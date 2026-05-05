# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class ToolsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @context = Kreator::ToolContext.new(cwd: @dir, bash_timeout: 2)
    @registry = Kreator::ToolRegistry.default(bash_timeout: 2)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_read_returns_truncated_text
    File.write(File.join(@dir, "notes.txt"), "one\ntwo\nthree\n")
    call = Kreator::ToolCall.new(id: "call_1", name: "read", arguments: { "path" => "notes.txt", "max_lines" => 2 })

    result = @registry.call(call, context: @context)

    assert_equal "ok", result.status
    assert_includes result.content, "one\ntwo\n"
    assert_includes result.content, "truncated after 2 lines"
    assert_equal "call_1", result.tool_call_id
  end

  def test_write_creates_parent_directories
    call = Kreator::ToolCall.new(id: "call_1", name: "write", arguments: { "path" => "tmp/out.txt", "content" => "hello" })

    result = @registry.call(call, context: @context)

    assert_equal "ok", result.status
    assert_equal "hello", File.read(File.join(@dir, "tmp/out.txt"))
    assert result.metadata.fetch("created")
  end

  def test_edit_replaces_exact_text_and_returns_diff
    path = File.join(@dir, "app.rb")
    File.write(path, "puts 'old'\n")
    call = Kreator::ToolCall.new(
      id: "call_1",
      name: "edit",
      arguments: { "path" => "app.rb", "old_string" => "old", "new_string" => "new" }
    )

    result = @registry.call(call, context: @context)

    assert_equal "ok", result.status
    assert_equal "puts 'new'\n", File.read(path)
    assert_includes result.content, "-puts 'old'"
    assert_includes result.content, "+puts 'new'"
  end

  def test_bash_runs_command_with_timeout_and_output
    call = Kreator::ToolCall.new(id: "call_1", name: "bash", arguments: { "command" => "printf hello" })

    result = @registry.call(call, context: @context)

    assert_equal "ok", result.status
    assert_includes result.content, "stdout:\nhello"
    assert_equal 0, result.metadata.fetch("exit_status")
  end

  def test_validation_failures_become_error_results
    call = Kreator::ToolCall.new(id: "call_1", name: "read", arguments: {})

    result = @registry.call(call, context: @context)

    assert_equal "error", result.status
    assert_includes result.content, "missing required properties"
    assert_equal "validation_error", result.error.fetch("code")
  end

  def test_path_allowlist_denies_file_access_outside_cwd
    outside_path = File.join(File.dirname(@dir), "outside.txt")
    call = Kreator::ToolCall.new(id: "call_1", name: "write", arguments: { "path" => outside_path, "content" => "nope" })

    result = @registry.call(call, context: @context)

    assert_equal "error", result.status
    assert_equal "permission_denied", result.error.fetch("code")
    refute File.exist?(outside_path)
  end

  def test_approval_policy_can_deny_mutating_tools
    context = Kreator::ToolContext.new(cwd: @dir, approval_policy: "deny")
    call = Kreator::ToolCall.new(id: "call_1", name: "write", arguments: { "path" => "out.txt", "content" => "nope" })

    result = @registry.call(call, context: context)

    assert_equal "error", result.status
    assert_equal "permission_denied", result.error.fetch("code")
    refute File.exist?(File.join(@dir, "out.txt"))
  end

  def test_bash_deny_patterns_block_commands
    context = Kreator::ToolContext.new(cwd: @dir, bash_deny_patterns: ["printf"])
    call = Kreator::ToolCall.new(id: "call_1", name: "bash", arguments: { "command" => "printf hello" })

    result = @registry.call(call, context: context)

    assert_equal "error", result.status
    assert_equal "permission_denied", result.error.fetch("code")
  end
end
