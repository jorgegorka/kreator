# frozen_string_literal: true

require "test_helper"

class ProvidersTest < Minitest::Test
  class FakeOpenAI < Kreator::Providers::OpenAI
    attr_reader :request_body, :request_headers

    def initialize(chunks)
      @chunks = chunks
      super(api_key: "openai-key", base_url: "https://openai.example/v1")
    end

    private

    def post_json_stream(_path, body, headers:, &)
      @request_body = body
      @request_headers = headers
      @chunks.each(&)
    end
  end

  class FakeAnthropic < Kreator::Providers::Anthropic
    attr_reader :request_body, :request_headers

    def initialize(chunks)
      @chunks = chunks
      super(api_key: "anthropic-key", base_url: "https://anthropic.example/v1")
    end

    private

    def post_json_stream(_path, body, headers:, &)
      @request_body = body
      @request_headers = headers
      @chunks.each(&)
    end
  end

  class FakeOpenRouter < Kreator::Providers::OpenRouter
    attr_reader :request_body, :request_headers

    def initialize(chunks)
      @chunks = chunks
      super(
        api_key: "openrouter-key",
        base_url: "https://openrouter.example/api/v1",
        site_url: "https://kreator.example",
        app_name: "Kreator"
      )
    end

    private

    def post_json_stream(_path, body, headers:, &)
      @request_body = body
      @request_headers = headers
      @chunks.each(&)
    end
  end

  def test_openai_normalizes_streaming_text_and_tool_calls
    provider = FakeOpenAI.new(
      [
        sse("choices" => [{ "delta" => { "content" => "hi " } }]),
        sse("choices" => [{ "delta" => { "content" => "there" } }]),
        sse(
          "choices" => [
            {
              "delta" => {
                "tool_calls" => [
                  {
                    "index" => 0,
                    "id" => "call_1",
                    "function" => { "name" => "read", "arguments" => "{\"path\"" }
                  }
                ]
              }
            }
          ]
        ),
        sse(
          "choices" => [
            {
              "delta" => {
                "tool_calls" => [
                  {
                    "index" => 0,
                    "function" => { "arguments" => ":\"README.md\"}" }
                  }
                ]
              }
            }
          ]
        ),
        "data: [DONE]\n\n"
      ]
    )

    events = []
    provider.stream(
      messages: [Kreator::Message.user("hello")],
      tools: [],
      system_prompt: "system",
      model: "model",
      signal: nil
    ) { |event| events << event }

    assert_equal %w[message_start message_delta message_delta tool_update tool_update message_end], event_types(events)
    assert_equal "Bearer openai-key", provider.request_headers.fetch("Authorization")
    assert_equal "system", provider.request_body.fetch(:messages).first.fetch(:content)
    tool_call = events.last.fetch(:tool_calls).first

    assert_equal "call_1", tool_call.id
    assert_equal "read", tool_call.name
    assert_equal({ "path" => "README.md" }, tool_call.arguments)
  end

  def test_openai_serializes_tool_call_conversation
    provider = FakeOpenAI.new(["data: [DONE]\n\n"])
    tool_call = Kreator::ToolCall.new(id: "call_1", name: "read", arguments: { "path" => "README.md" })
    events = []

    provider.stream(
      messages: [
        Kreator::Message.user("hello"),
        Kreator::Message.assistant("", tool_calls: [tool_call]),
        Kreator::Message.tool(content: "readme", tool_call_id: "call_1", name: "read")
      ],
      tools: [Kreator::Tools::Read.new],
      system_prompt: "system",
      model: "model",
      signal: nil
    ) { |event| events << event }

    assistant = provider.request_body.fetch(:messages)[2]
    tool = provider.request_body.fetch(:messages)[3]

    assert_equal "assistant", assistant.fetch(:role)
    assert_equal "function", assistant.fetch(:tool_calls).first.fetch(:type)
    assert_equal({ "path" => "README.md" }, JSON.parse(assistant.fetch(:tool_calls).first.fetch(:function).fetch(:arguments)))
    assert_equal "tool", tool.fetch(:role)
    assert_equal "call_1", tool.fetch(:tool_call_id)
  end

  def test_openai_emits_usage_events_and_capabilities
    provider = FakeOpenAI.new(
      [
        sse("choices" => [{ "delta" => { "content" => "hi" } }]),
        sse("choices" => [], "usage" => { "prompt_tokens" => 2, "completion_tokens" => 3, "total_tokens" => 5 }),
        "data: [DONE]\n\n"
      ]
    )

    events = []
    provider.stream(
      messages: [Kreator::Message.user("hello")],
      tools: [],
      system_prompt: "system",
      model: "gpt-5.5",
      signal: nil
    ) { |event| events << event }

    usage = events.find { |event| event.fetch(:type) == "usage" }.fetch(:usage)

    assert_equal 5, usage.fetch("total_tokens")
    assert provider.capabilities("gpt-5.5").fetch("vision")
    assert_equal 400_000, provider.capabilities("gpt-5.5").fetch("context_window")
    assert provider.capabilities("gpt-5.5").fetch("reasoning")
  end

  def test_openrouter_uses_openai_compatible_streaming_with_openrouter_headers
    provider = FakeOpenRouter.new(
      [
        sse("choices" => [{ "delta" => { "content" => "hi" } }]),
        "data: [DONE]\n\n"
      ]
    )

    events = []
    provider.stream(
      messages: [Kreator::Message.user("hello")],
      tools: [],
      system_prompt: "system",
      model: "openai/gpt-5.5",
      signal: nil
    ) { |event| events << event }

    assert_equal %w[message_start message_delta message_end], event_types(events)
    assert_equal "Bearer openrouter-key", provider.request_headers.fetch("Authorization")
    assert_equal "https://kreator.example", provider.request_headers.fetch("HTTP-Referer")
    assert_equal "Kreator", provider.request_headers.fetch("X-OpenRouter-Title")
    assert_equal "openai/gpt-5.5", provider.request_body.fetch(:model)
    assert_equal "openrouter", provider.capabilities("openai/gpt-5.5").fetch("provider")
    assert_equal 400_000, provider.capabilities("openai/gpt-5.5").fetch("context_window")
  end

  def test_anthropic_normalizes_streaming_text_and_tool_calls
    provider = FakeAnthropic.new(
      [
        sse("type" => "message_start"),
        sse("type" => "content_block_delta", "index" => 0, "delta" => { "type" => "text_delta", "text" => "hi" }),
        sse(
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => { "type" => "tool_use", "id" => "toolu_1", "name" => "read", "input" => { "path" => "README.md" } }
        ),
        sse("type" => "message_stop")
      ]
    )

    events = []
    provider.stream(
      messages: [Kreator::Message.user("hello")],
      tools: [],
      system_prompt: "system",
      model: "model",
      signal: nil
    ) { |event| events << event }

    assert_equal %w[message_start message_delta tool_start message_end], event_types(events)
    assert_equal "anthropic-key", provider.request_headers.fetch("x-api-key")
    assert_equal "system", provider.request_body.fetch(:system)
    tool_call = events.last.fetch(:tool_calls).first

    assert_equal "toolu_1", tool_call.id
    assert_equal "read", tool_call.name
    assert_equal({ "path" => "README.md" }, tool_call.arguments)
  end

  def test_anthropic_serializes_tool_call_conversation
    provider = FakeAnthropic.new([sse("type" => "message_stop")])
    tool_call = Kreator::ToolCall.new(id: "toolu_1", name: "read", arguments: { "path" => "README.md" })
    events = []

    provider.stream(
      messages: [
        Kreator::Message.user("hello"),
        Kreator::Message.assistant("", tool_calls: [tool_call]),
        Kreator::Message.tool(content: "readme", tool_call_id: "toolu_1", name: "read")
      ],
      tools: [Kreator::Tools::Read.new],
      system_prompt: "system",
      model: "model",
      signal: nil
    ) { |event| events << event }

    assistant = provider.request_body.fetch(:messages)[1]
    tool = provider.request_body.fetch(:messages)[2]

    assert_equal "assistant", assistant.fetch(:role)
    assert_equal "tool_use", assistant.fetch(:content).first.fetch(:type)
    assert_equal({ "path" => "README.md" }, assistant.fetch(:content).first.fetch(:input))
    assert_equal "user", tool.fetch(:role)
    assert_equal "tool_result", tool.fetch(:content).first.fetch(:type)
    assert_equal "toolu_1", tool.fetch(:content).first.fetch(:tool_use_id)
  end

  private

  def event_types(events)
    events.map { |event| event.fetch(:type) }
  end

  def sse(payload)
    "data: #{JSON.generate(payload)}\n\n"
  end
end
