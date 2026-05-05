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
      yield type: "message_end"
    end
  end

  def test_runs_provider_stream_and_emits_lifecycle_events
    provider = FakeProvider.new
    bus = Kreator::EventBus.new
    events = []
    bus.subscribe { |event| events << event }

    message = Kreator::AgentLoop.new(provider: provider, event_bus: bus, model: "test-model").run(prompt: "Say hi")

    assert_equal "hello world", message.content
    assert_equal ["Say hi"], provider.received.fetch(:messages).map(&:content)
    assert_equal "test-model", provider.received.fetch(:model)
    assert_equal(
      %w[
        agent_start
        turn_start
        message_start
        message_delta
        message_delta
        message_end
        turn_end
        agent_end
      ],
      events.map { |event| event.fetch(:type) }
    )
  end
end
