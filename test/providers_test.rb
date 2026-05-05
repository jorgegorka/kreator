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

    def post_json_stream(_path, body, headers:)
      @request_body = body
      @request_headers = headers
      @chunks.each { |chunk| yield chunk }
    end
  end

  class FakeAnthropic < Kreator::Providers::Anthropic
    attr_reader :request_body, :request_headers

    def initialize(chunks)
      @chunks = chunks
      super(api_key: "anthropic-key", base_url: "https://anthropic.example/v1")
    end

    private

    def post_json_stream(_path, body, headers:)
      @request_body = body
      @request_headers = headers
      @chunks.each { |chunk| yield chunk }
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

  private

  def event_types(events)
    events.map { |event| event.fetch(:type) }
  end

  def sse(payload)
    "data: #{JSON.generate(payload)}\n\n"
  end
end
