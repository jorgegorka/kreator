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

  def test_default_registry_includes_safe_discovery_tools
    assert_equal %w[read grep find ls edit write bash agent], @registry.names
  end

  def test_grep_searches_text_files_with_glob_and_case_option
    FileUtils.mkdir_p(File.join(@dir, "app", "models"))
    File.write(File.join(@dir, "app", "models", "user.rb"), "class User\nend\n")
    File.write(File.join(@dir, "notes.txt"), "User notes\n")
    call = Kreator::ToolCall.new(
      id: "call_1",
      name: "grep",
      arguments: { "pattern" => "user", "case_sensitive" => false, "glob" => "**/*.rb" }
    )

    result = @registry.call(call, context: @context)

    assert_equal "ok", result.status
    assert_includes result.content, "app/models/user.rb:1:class User"
    refute_includes result.content, "notes.txt"
    assert_equal 1, result.metadata.fetch("matches")
  end

  def test_grep_skips_hidden_files_by_default_and_can_include_them
    File.write(File.join(@dir, ".secret.txt"), "needle\n")

    hidden = Kreator::ToolCall.new(id: "call_1", name: "grep", arguments: { "pattern" => "needle" })
    visible = Kreator::ToolCall.new(id: "call_2", name: "grep", arguments: { "pattern" => "needle", "include_hidden" => true })

    hidden_result = @registry.call(hidden, context: @context)
    visible_result = @registry.call(visible, context: @context)

    assert_equal "(no matches)", hidden_result.content
    assert_includes visible_result.content, ".secret.txt:1:needle"
  end

  def test_grep_truncates_by_result_count_and_bytes
    File.write(File.join(@dir, "notes.txt"), "needle one\nneedle two\n")
    count_call = Kreator::ToolCall.new(id: "call_1", name: "grep", arguments: { "pattern" => "needle", "max_results" => 1 })
    bytes_call = Kreator::ToolCall.new(id: "call_2", name: "grep", arguments: { "pattern" => "needle", "max_bytes" => 10 })

    count_result = @registry.call(count_call, context: @context)
    bytes_result = @registry.call(bytes_call, context: @context)

    assert_equal 1, count_result.metadata.fetch("matches")
    assert count_result.metadata.fetch("result_truncated")
    assert bytes_result.metadata.fetch("byte_truncated")
    assert_includes bytes_result.content, "truncated after 10 bytes"
  end

  def test_grep_denies_paths_outside_allowlist
    outside_path = File.join(File.dirname(@dir), "outside.txt")
    File.write(outside_path, "needle\n")
    call = Kreator::ToolCall.new(id: "call_1", name: "grep", arguments: { "pattern" => "needle", "path" => outside_path })

    result = @registry.call(call, context: @context)

    assert_equal "error", result.status
    assert_equal "permission_denied", result.error.fetch("code")
  ensure
    FileUtils.rm_f(outside_path)
  end

  def test_find_filters_by_name_type_and_hidden_files
    FileUtils.mkdir_p(File.join(@dir, "app", "models"))
    File.write(File.join(@dir, "app", "models", "user.rb"), "")
    File.write(File.join(@dir, ".secret.rb"), "")
    call = Kreator::ToolCall.new(id: "call_1", name: "find", arguments: { "name" => "*.rb", "type" => "file" })
    hidden_call = Kreator::ToolCall.new(id: "call_2", name: "find", arguments: { "name" => ".secret.rb", "type" => "file" })
    include_hidden_call = Kreator::ToolCall.new(id: "call_3", name: "find", arguments: { "name" => ".secret.rb", "include_hidden" => true })

    result = @registry.call(call, context: @context)
    hidden_result = @registry.call(hidden_call, context: @context)
    include_hidden_result = @registry.call(include_hidden_call, context: @context)

    assert_includes result.content, "app/models/user.rb"
    refute_includes result.content, ".secret.rb"
    assert_equal "(no matches)", hidden_result.content
    assert_includes include_hidden_result.content, ".secret.rb"
  end

  def test_find_truncates_results
    File.write(File.join(@dir, "a.txt"), "")
    File.write(File.join(@dir, "b.txt"), "")
    call = Kreator::ToolCall.new(id: "call_1", name: "find", arguments: { "name" => "*.txt", "max_results" => 1 })

    result = @registry.call(call, context: @context)

    assert_equal 1, result.metadata.fetch("matches")
    assert result.metadata.fetch("result_truncated")
  end

  def test_find_denies_paths_outside_allowlist
    outside_dir = Dir.mktmpdir
    call = Kreator::ToolCall.new(id: "call_1", name: "find", arguments: { "path" => outside_dir })

    result = @registry.call(call, context: @context)

    assert_equal "error", result.status
    assert_equal "permission_denied", result.error.fetch("code")
  ensure
    FileUtils.remove_entry(outside_dir) if outside_dir && Dir.exist?(outside_dir)
  end

  def test_ls_lists_directory_entries_with_metadata
    FileUtils.mkdir_p(File.join(@dir, "app"))
    File.write(File.join(@dir, "app", "model.rb"), "puts 1\n")
    call = Kreator::ToolCall.new(id: "call_1", name: "ls", arguments: { "path" => "app" })

    result = @registry.call(call, context: @context)

    assert_equal "ok", result.status
    assert_includes result.content, "model.rb\tfile\t7"
    assert_equal "file", result.metadata.fetch("entries").first.fetch("type")
  end

  def test_ls_recurses_honors_hidden_files_and_truncates
    FileUtils.mkdir_p(File.join(@dir, "app", "models"))
    File.write(File.join(@dir, "app", ".hidden"), "")
    File.write(File.join(@dir, "app", "models", "user.rb"), "")
    hidden_call = Kreator::ToolCall.new(id: "call_1", name: "ls", arguments: { "path" => "app", "recursive" => true })
    visible_call = Kreator::ToolCall.new(id: "call_2", name: "ls", arguments: { "path" => "app", "recursive" => true, "include_hidden" => true, "max_results" => 1 })

    hidden_result = @registry.call(hidden_call, context: @context)
    visible_result = @registry.call(visible_call, context: @context)

    assert_includes hidden_result.content, "models/user.rb"
    refute_includes hidden_result.content, ".hidden"
    assert visible_result.metadata.fetch("result_truncated")
  end

  def test_ls_denies_paths_outside_allowlist
    outside_dir = Dir.mktmpdir
    call = Kreator::ToolCall.new(id: "call_1", name: "ls", arguments: { "path" => outside_dir })

    result = @registry.call(call, context: @context)

    assert_equal "error", result.status
    assert_equal "permission_denied", result.error.fetch("code")
  ensure
    FileUtils.remove_entry(outside_dir) if outside_dir && Dir.exist?(outside_dir)
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

  def test_agent_start_launches_detached_tmux_session
    tmux_args_path = File.join(@dir, "tmux_args.txt")
    with_fake_tmux(tmux_args_path) do
      with_env("KREATOR_HOME" => File.join(@dir, "home"), "KREATOR_AGENT_EXECUTABLE" => "/tmp/kreator") do
        call = Kreator::ToolCall.new(
          id: "call_1",
          name: "agent",
          arguments: {
            "action" => "start",
            "prompt" => "inspect the repo",
            "name" => "review",
            "provider" => "openai",
            "model" => "gpt-test",
            "tools" => %w[read bash]
          }
        )

        result = @registry.call(call, context: @context)

        assert_equal "ok", result.status
        assert_match(/\Aagent_/, result.metadata.fetch("id"))
        assert_includes result.content, "started agent"
        assert File.file?(result.metadata.fetch("path"))
        tmux_args = File.read(tmux_args_path)

        assert_includes tmux_args, "new-session"
        assert_includes tmux_args, "kreator-review"
        assert_includes tmux_args, "--model gpt-test"
        assert_includes tmux_args, "--tools read,bash"
        assert_includes tmux_args, "inspect\\ the\\ repo"
      end
    end
  end

  def test_agent_capture_reads_log_and_status
    with_env("KREATOR_HOME" => File.join(@dir, "home")) do
      record = write_agent_record("agent_test")
      File.write(record.fetch("log_path"), "done\n")
      File.write(record.fetch("status_path"), JSON.generate("exit_status" => 0))

      call = Kreator::ToolCall.new(id: "call_1", name: "agent", arguments: { "action" => "capture", "id" => "agent_test" })

      result = @registry.call(call, context: @context)

      assert_equal "ok", result.status
      assert_equal "done\n", result.content
      assert_equal 0, result.metadata.fetch("status_record").fetch("exit_status")
    end
  end

  def test_agent_wait_reports_failed_child_status
    with_env("KREATOR_HOME" => File.join(@dir, "home")) do
      record = write_agent_record("agent_test")
      File.write(record.fetch("log_path"), "failed\n")
      File.write(record.fetch("status_path"), JSON.generate("exit_status" => 2))

      call = Kreator::ToolCall.new(id: "call_1", name: "agent", arguments: { "action" => "wait", "id" => "agent_test" })

      result = @registry.call(call, context: @context)

      assert_equal "error", result.status
      assert_equal "exit_status", result.error.fetch("code")
      assert_includes result.content, "failed"
    end
  end

  def test_agent_start_respects_approval_policy
    context = Kreator::ToolContext.new(cwd: @dir, approval_policy: "deny")
    call = Kreator::ToolCall.new(id: "call_1", name: "agent", arguments: { "action" => "start", "prompt" => "do work" })

    result = @registry.call(call, context: context)

    assert_equal "error", result.status
    assert_equal "permission_denied", result.error.fetch("code")
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

  private

  def with_env(values)
    previous = values.to_h { |key, _value| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def with_fake_tmux(args_path, &)
    bin_dir = File.join(@dir, "bin")
    FileUtils.mkdir_p(bin_dir)
    tmux_path = File.join(bin_dir, "tmux")
    File.write(
      tmux_path,
      <<~SH
        #!/bin/sh
        if [ "$1" = "-V" ]; then
          echo "tmux 3.4"
          exit 0
        fi
        if [ "$1" = "new-session" ]; then
          printf '%s\\n' "$@" > "$TMUX_ARGS_PATH"
          exit 0
        fi
        if [ "$1" = "has-session" ]; then
          exit 0
        fi
        if [ "$1" = "kill-session" ]; then
          exit 0
        fi
        exit 1
      SH
    )
    FileUtils.chmod("+x", tmux_path)
    with_env("PATH" => "#{bin_dir}:#{ENV.fetch('PATH', '')}", "TMUX_ARGS_PATH" => args_path, &)
  end

  def write_agent_record(id)
    agent_home = File.join(ENV.fetch("KREATOR_HOME"), "agents")
    FileUtils.mkdir_p(agent_home)
    record = {
      "id" => id,
      "cwd" => @dir,
      "tmux_session" => "kreator-test",
      "path" => File.join(agent_home, "#{id}.json"),
      "log_path" => File.join(agent_home, "#{id}.log"),
      "status_path" => File.join(agent_home, "#{id}.status.json")
    }
    File.write(record.fetch("path"), JSON.generate(record))
    record
  end
end
