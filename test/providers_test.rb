# frozen_string_literal: true

require "test_helper"
require "tmpdir"

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

  class FakeOpenAIOAuth < Kreator::Providers::OpenAI
    attr_reader :request_body, :request_headers, :request_path

    def initialize(chunks, auth:)
      @chunks = chunks
      super(auth: auth, base_url: "https://openai.example/v1")
    end

    private

    def post_json_stream(path, body, headers:, &)
      @request_path = path
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

  def test_openai_resolves_pi_oauth_credentials
    Dir.mktmpdir do |dir|
      path = File.join(dir, "auth.json")
      token = jwt("https://api.openai.com/auth" => { "chatgpt_account_id" => "acct_pi", "chatgpt_plan_type" => "pro" })
      File.write(
        path,
        JSON.generate(
          "openai-codex" => {
            "type" => "oauth",
            "access" => token,
            "refresh" => "refresh-token",
            "expires" => ((Time.now.to_f + 3600) * 1000).to_i
          }
        )
      )

      auth = without_openai_api_key_env do
        Kreator::Providers::OpenAIAuth.resolve(auth_file: path)
      end

      assert_predicate auth, :oauth?
      assert_equal token, auth.token
      assert_equal "acct_pi", auth.account_id
      assert_equal "pro", auth.plan_type
    end
  end

  def test_openai_logout_removes_kreator_oauth_credentials
    Dir.mktmpdir do |dir|
      path = File.join(dir, "auth.json")
      File.write(
        path,
        JSON.pretty_generate(
          "openai-codex" => { "type" => "oauth", "access" => "access", "refresh" => "refresh" },
          "other" => "kept"
        )
      )

      result = Kreator::Providers::OpenAIAuth.logout(auth_file: path)
      auth_json = JSON.parse(File.read(path))

      assert result.fetch(:removed)
      assert_equal path, result.fetch(:auth_file)
      refute auth_json.key?("openai-codex")
      assert_equal "kept", auth_json.fetch("other")
    end
  end

  def test_openai_logout_reports_missing_credentials
    Dir.mktmpdir do |dir|
      path = File.join(dir, "auth.json")

      result = Kreator::Providers::OpenAIAuth.logout(auth_file: path)

      refute result.fetch(:removed)
      assert_equal path, result.fetch(:auth_file)
    end
  end

  def test_openai_oauth_uses_codex_responses_stream
    auth = Kreator::Providers::OpenAIAuth.new(
      mode: :oauth,
      token: "oauth-token",
      account_id: "acct_123"
    )
    provider = FakeOpenAIOAuth.new(
      [
        sse("type" => "response.output_text.delta", "delta" => "hi "),
        sse(
          "type" => "response.output_item.added",
          "output_index" => 1,
          "item" => { "type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "read", "arguments" => "" }
        ),
        sse("type" => "response.function_call_arguments.delta", "output_index" => 1, "item_id" => "fc_1", "delta" => "{\"path\""),
        sse(
          "type" => "response.function_call_arguments.done",
          "output_index" => 1,
          "item_id" => "fc_1",
          "call_id" => "call_1",
          "name" => "read",
          "arguments" => "{\"path\":\"README.md\"}"
        ),
        sse("type" => "response.completed", "response" => { "usage" => { "input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5 } }),
        "data: [DONE]\n\n"
      ],
      auth: auth
    )

    events = []
    provider.stream(
      messages: [Kreator::Message.user("hello")],
      tools: [Kreator::Tools::Read.new],
      system_prompt: "system",
      model: "gpt-5.5",
      signal: nil
    ) { |event| events << event }

    assert_equal "https://chatgpt.com/backend-api/codex/responses", provider.request_path
    assert_equal "Bearer oauth-token", provider.request_headers.fetch("Authorization")
    assert_equal "acct_123", provider.request_headers.fetch("chatgpt-account-id")
    assert_equal "responses=experimental", provider.request_headers.fetch("OpenAI-Beta")
    assert_equal "system", provider.request_body.fetch(:instructions)
    assert_equal "hello", provider.request_body.fetch(:input).first.fetch(:content).first.fetch(:text)
    assert_equal "function", provider.request_body.fetch(:tools).first.fetch(:type)

    assert_equal %w[message_start message_delta tool_update tool_update tool_update usage message_end], event_types(events)
    tool_call = events.last.fetch(:tool_calls).first

    assert_equal "call_1", tool_call.id
    assert_equal "read", tool_call.name
    assert_equal({ "path" => "README.md" }, tool_call.arguments)
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

  def jwt(payload)
    encoded_header = base64_url(JSON.generate({ "alg" => "none" }))
    encoded_payload = base64_url(JSON.generate(payload))
    "#{encoded_header}.#{encoded_payload}.signature"
  end

  def base64_url(value)
    [value].pack("m0").tr("+/", "-_").delete("=")
  end

  def without_openai_api_key_env
    previous_codex = ENV.delete("CODEX_API_KEY")
    previous_openai = ENV.delete("OPENAI_API_KEY")
    yield
  ensure
    ENV["CODEX_API_KEY"] = previous_codex if previous_codex
    ENV["OPENAI_API_KEY"] = previous_openai if previous_openai
  end
end
