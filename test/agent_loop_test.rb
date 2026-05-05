# frozen_string_literal: true

require "test_helper"

class AgentLoopTest < Minitest::Test
  class FakeProvider
    attr_reader :received

    def name
      "fake"
    end

    def stream(messages:, tools:, system_prompt:, model:, signal:)
      @received = {
        messages: messages,
        tools: tools,
        system_prompt: system_prompt,
        model: model,
        signal: signal
      }

      yield type: "message_start", role: "assistant"
      yield type: "message_delta", delta: "hello"
      yield type: "message_delta", delta: " world"
      yield type: "usage", usage: { "input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3 }
      yield type: "message_end"
    end
  end

  class ToolUsingProvider
    attr_reader :requests

    def initialize
      @requests = []
    end

    def name
      "tool-using"
    end

    def stream(messages:, tools:, **_options)
      @requests << { messages: messages, tools: tools }

      yield type: "message_start", role: "assistant"
      if messages.any? { |message| message.role == "tool" }
        yield type: "message_delta", delta: "Read result: #{messages.last.content}"
        yield type: "message_end"
      else
        yield(
          type: "message_end",
          tool_calls: [
            Kreator::ToolCall.new(id: "call_1", name: "read", arguments: { "path" => "README.md", "max_lines" => 1 })
          ]
        )
      end
    end
  end

  def test_runs_provider_stream_and_emits_lifecycle_events
    provider = FakeProvider.new
    bus = Kreator::EventBus.new
    events = []
    bus.subscribe { |event| events << event }

    agent = Kreator::AgentLoop.new(provider: provider, event_bus: bus, model: "test-model")
    message = agent.run(prompt: "Say hi")

    assert_equal "hello world", message.content
    assert_equal 3, agent.last_usage.fetch("total_tokens")
    assert_equal ["Say hi"], provider.received.fetch(:messages).map(&:content)
    assert_equal "test-model", provider.received.fetch(:model)
    assert_equal(
      %w[
        agent_start
        turn_start
        message_start
        message_delta
        message_delta
        usage
        message_end
        turn_end
        agent_end
      ],
      events.map { |event| event.fetch(:type) }
    )
  end

  def test_executes_tool_calls_and_continues_with_tool_result
    provider = ToolUsingProvider.new
    bus = Kreator::EventBus.new
    events = []
    bus.subscribe { |event| events << event }
    context = Kreator::ToolContext.new(cwd: File.expand_path("..", __dir__))

    message = Kreator::AgentLoop.new(provider: provider, event_bus: bus, model: "test-model", context: context).run(prompt: "Read")

    assert_includes message.content, "Read result:"
    assert_equal 2, provider.requests.length
    assert_equal %w[read grep find ls edit write bash agent], provider.requests.first.fetch(:tools).map(&:name)
    assert_equal "tool", provider.requests.last.fetch(:messages).last.role
    assert_includes events.map { |event| event.fetch(:type) }, "tool_end"
  end
end
