# frozen_string_literal: true

require "stringio"
require "test_helper"

class CLITest < Minitest::Test
  class FakeProvider
    def stream(messages:, tools:, system_prompt:, model:, signal:)
      yield type: "message_start", role: "assistant"
      yield type: "message_delta", delta: "#{model}: #{messages.last.content}"
      yield type: "message_end"
    end
  end

  def test_print_mode_streams_assistant_text
    stdout = StringIO.new
    stderr = StringIO.new

    status = Kreator::CLI.new(
      ["--model", "fake-model", "Hello"],
      stdout: stdout,
      stderr: stderr,
      provider_builder: ->(_name) { FakeProvider.new }
    ).run

    assert_equal 0, status
    assert_equal "fake-model: Hello\n", stdout.string
    assert_equal "", stderr.string
  end

  def test_missing_prompt_prints_usage
    stdout = StringIO.new
    stderr = StringIO.new

    status = Kreator::CLI.new([], stdout: stdout, stderr: stderr).run

    assert_equal 1, status
    assert_includes stderr.string, "Usage: kreator"
  end
end
