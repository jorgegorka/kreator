# frozen_string_literal: true

module Kreator
  module Providers
    class OpenAI < Base
      DEFAULT_BASE_URL = "https://api.openai.com/v1"
      DEFAULT_CODEX_BASE_URL = "https://chatgpt.com/backend-api"
      CODEX_EVENT_HANDLERS = {
        "response.output_text.delta" => :handle_codex_text_delta,
        "response.output_item.added" => :handle_codex_output_item_added,
        "response.function_call_arguments.delta" => :handle_codex_function_arguments_delta,
        "response.function_call_arguments.done" => :handle_codex_function_arguments_done,
        "response.output_item.done" => :handle_codex_output_item_done,
        "response.completed" => :handle_codex_response_completed,
        "response.done" => :handle_codex_response_completed,
        "response.failed" => :raise_codex_response_failed,
        "error" => :raise_codex_error
      }.freeze

      def initialize(
        api_key: nil,
        base_url: ENV.fetch("OPENAI_BASE_URL", DEFAULT_BASE_URL),
        name: "openai",
        max_retries: DEFAULT_MAX_RETRIES,
        auth: OpenAIAuth.resolve(api_key: api_key)
      )
        raise Error, "OPENAI_API_KEY or OpenAI Codex/PI OAuth credentials are required for the openai provider" unless auth

        @auth = auth
        super(api_key: auth.token, base_url: base_url, name: name, max_retries: max_retries)
      end

      def stream(messages:, tools:, system_prompt:, model:, signal:, &)
        return stream_codex_responses(messages: messages, tools: tools, system_prompt: system_prompt, model: model, signal: signal, &) if oauth_auth?

        yield type: "message_start", role: "assistant"

        body = openai_stream_body(messages, tools, system_prompt, model)
        stream_state = {
          tool_call_builders: {},
          emitted_model_output: false
        }

        begin
          stream_openai_events(body, signal, stream_state, &)

          tool_calls = stream_state.fetch(:tool_call_builders).values.map { |builder| build_tool_call(builder) }
          yield type: "message_end", tool_calls: tool_calls
        rescue Providers::Error
          raise if stream_state.fetch(:emitted_model_output)

          complete_once(body.merge(stream: false).except(:stream_options), &)
        end
      end

      def capabilities(model)
        context_window =
          case model.to_s
          when /gpt-5(?:\.|-|\z)/
            400_000
          when /4\.1/, /4o/
            128_000
          end

        super.merge(
          "vision" => model.to_s.match?(/gpt-5|4o|4\.1/),
          "reasoning" => model.to_s.match?(/gpt-5|o[134]|reasoning/),
          "context_window" => context_window
        )
      end

      private

      def oauth_auth?
        @auth&.oauth? && name == "openai"
      end

      def openai_stream_body(messages, tools, system_prompt, model)
        {
          model: model,
          stream: true,
          stream_options: { include_usage: true },
          messages: openai_messages(messages, system_prompt),
          tools: openai_tools(tools)
        }.compact
      end

      def stream_openai_events(body, signal, stream_state, &block)
        parse_sse_stream(openai_stream_producer(body, signal)) do |data|
          break if data == "[DONE]"

          handle_openai_event(JSON.parse(data), stream_state, &block)
        end
      end

      def openai_stream_producer(body, signal)
        lambda do |push_chunk|
          post_json_stream("chat/completions", body, headers: openai_headers) do |chunk|
            break if signal.respond_to?(:aborted?) && signal.aborted?

            push_chunk.call(chunk)
          end
        end
      end

      def openai_headers
        { "Authorization" => "Bearer #{api_key}" }
      end

      def stream_codex_responses(messages:, tools:, system_prompt:, model:, signal:, &block)
        block.call type: "message_start", role: "assistant"

        stream_state = {
          tool_call_builders: {},
          emitted_model_output: false
        }

        parse_sse_stream(codex_stream_producer(codex_response_body(messages, tools, system_prompt, model), signal)) do |data|
          break if data == "[DONE]"

          handle_codex_event(JSON.parse(data), stream_state, &block)
        end

        tool_calls = stream_state.fetch(:tool_call_builders).values.map { |builder| build_tool_call(builder) }
        block.call type: "message_end", tool_calls: tool_calls
      rescue JSON::ParserError => e
        raise Error.new("invalid #{name} SSE JSON response: #{e.message}", code: "invalid_response")
      end

      def codex_response_body(messages, tools, system_prompt, model)
        {
          model: model,
          store: false,
          stream: true,
          instructions: system_prompt.to_s.empty? ? "You are a helpful assistant." : system_prompt,
          input: response_input(messages),
          tools: response_tools(tools),
          tool_choice: tools.empty? ? nil : "auto",
          parallel_tool_calls: tools.empty? ? nil : true,
          text: { verbosity: "low" }
        }.compact
      end

      def codex_stream_producer(body, signal)
        lambda do |push_chunk|
          post_json_stream(codex_response_path, body, headers: codex_headers) do |chunk|
            break if signal.respond_to?(:aborted?) && signal.aborted?

            push_chunk.call(chunk)
          end
        end
      end

      def codex_response_path
        base = ENV.fetch("OPENAI_CODEX_BASE_URL", DEFAULT_CODEX_BASE_URL)
        normalized = base.sub(%r{/+\z}, "")
        return normalized if normalized.match?(%r{\Ahttps?://}) && normalized.end_with?("/codex/responses")
        return "#{normalized}/responses" if normalized.match?(%r{\Ahttps?://}) && normalized.end_with?("/codex")
        return "#{normalized}/codex/responses" if normalized.match?(%r{\Ahttps?://})

        "codex/responses"
      end

      def codex_headers
        headers = {
          "Authorization" => "Bearer #{api_key}",
          "OpenAI-Beta" => "responses=experimental",
          "Accept" => "text/event-stream",
          "originator" => "kreator"
        }
        headers["chatgpt-account-id"] = @auth.account_id unless @auth.account_id.to_s.empty?
        headers
      end

      def response_input(messages)
        messages.flat_map do |message|
          case message.role
          when "user"
            [{ role: "user", content: [{ type: "input_text", text: message.content }] }]
          when "assistant"
            response_assistant_items(message)
          when "tool"
            [{ type: "function_call_output", call_id: message.tool_call_id, output: message.content }]
          else
            [{ role: message.role, content: message.content }]
          end
        end
      end

      def response_assistant_items(message)
        items = []
        unless message.content.to_s.empty?
          items << {
            type: "message",
            role: "assistant",
            content: [{ type: "output_text", text: message.content, annotations: [] }],
            status: "completed"
          }
        end
        message.tool_calls.each do |tool_call|
          items << {
            type: "function_call",
            call_id: tool_call.id,
            name: tool_call.name,
            arguments: JSON.generate(tool_call.arguments)
          }
        end
        items
      end

      def response_tools(tools)
        return nil if tools.empty?

        tools.map do |tool|
          {
            type: "function",
            name: tool.name,
            description: tool.description,
            parameters: tool.schema,
            strict: nil
          }
        end
      end

      def handle_codex_event(event, stream_state, &)
        handler = CODEX_EVENT_HANDLERS[event["type"]]
        send(handler, event, stream_state, &) if handler
      end

      def handle_codex_text_delta(event, stream_state)
        delta = event["delta"].to_s
        return if delta.empty?

        stream_state[:emitted_model_output] = true
        yield type: "message_delta", delta: delta
      end

      def handle_codex_output_item_added(event, stream_state)
        item = event["item"] || {}
        return unless item["type"] == "function_call"

        update_response_tool_call_builder(stream_state.fetch(:tool_call_builders), item, event)
        stream_state[:emitted_model_output] = true
        yield type: "tool_update", index: event.fetch("output_index", 0), delta: item
      end

      def handle_codex_function_arguments_delta(event, stream_state)
        builder = response_tool_call_builder(stream_state.fetch(:tool_call_builders), event)
        builder[:raw_arguments] << event["delta"].to_s
        stream_state[:emitted_model_output] = true
        yield type: "tool_update", index: event.fetch("output_index", 0), delta: event
      end

      def handle_codex_function_arguments_done(event, stream_state)
        builder = response_tool_call_builder(stream_state.fetch(:tool_call_builders), event)
        builder[:id] = event["call_id"] if event["call_id"]
        builder[:name] = event["name"] if event["name"]
        builder[:raw_arguments] = event["arguments"].to_s if event["arguments"]
        stream_state[:emitted_model_output] = true
        yield type: "tool_update", index: event.fetch("output_index", 0), delta: event
      end

      def handle_codex_output_item_done(event, stream_state)
        item = event["item"] || {}
        return unless item["type"] == "function_call"

        update_response_tool_call_builder(stream_state.fetch(:tool_call_builders), item, event)
      end

      def handle_codex_response_completed(event, _stream_state)
        response = event["response"] || {}
        yield usage_event(response) if response["usage"]
      end

      def raise_codex_response_failed(event, _stream_state)
        error = event.dig("response", "error") || {}
        raise Error.new("OpenAI Codex response failed: #{error['message'] || event}", code: error["code"] || "response_failed")
      end

      def raise_codex_error(event, _stream_state)
        raise Error.new("OpenAI Codex error: #{event['message'] || event}", code: event["code"] || "provider_error")
      end

      def update_response_tool_call_builder(tool_call_builders, item, event)
        builder = response_tool_call_builder(tool_call_builders, event.merge("item_id" => item["id"], "call_id" => item["call_id"]))
        builder[:id] = item["call_id"] if item["call_id"]
        builder[:name] = item["name"] if item["name"]
        builder[:raw_arguments] = item["arguments"].to_s if item["arguments"] && builder[:raw_arguments].empty?
      end

      def response_tool_call_builder(tool_call_builders, event)
        key = event["item_id"] || event["call_id"] || event.fetch("output_index", 0)
        tool_call_builders[key] ||= empty_tool_call_builder
      end

      def handle_openai_event(chunk, stream_state, &block)
        block.call(usage_event(chunk)) if chunk["usage"]

        delta = openai_delta(chunk)
        emit_openai_content_delta(delta, stream_state, &block)
        emit_openai_tool_deltas(delta, stream_state, &block)
      end

      def openai_delta(chunk)
        choice = chunk.fetch("choices", [{}]).first || {}
        choice.fetch("delta", {})
      end

      def emit_openai_content_delta(delta, stream_state, &block)
        return unless delta["content"]

        stream_state[:emitted_model_output] = true
        block.call(type: "message_delta", delta: delta["content"])
      end

      def emit_openai_tool_deltas(delta, stream_state, &block)
        Array(delta["tool_calls"]).each do |tool_call_delta|
          stream_state[:emitted_model_output] = true
          update_tool_call_builder(stream_state.fetch(:tool_call_builders), tool_call_delta)
          block.call(type: "tool_update", index: tool_call_delta.fetch("index"), delta: tool_call_delta)
        end
      end

      def update_tool_call_builder(tool_call_builders, tool_call_delta)
        builder = tool_call_builders[tool_call_delta.fetch("index")] ||= empty_tool_call_builder
        builder[:id] = tool_call_delta["id"] if tool_call_delta["id"]
        function = tool_call_delta["function"] || {}
        builder[:name] = function["name"] if function["name"]
        builder[:raw_arguments] << function["arguments"].to_s if function["arguments"]
      end

      def empty_tool_call_builder
        {
          id: nil,
          name: nil,
          raw_arguments: +""
        }
      end

      def complete_once(body)
        response = post_json("chat/completions", body, headers: openai_headers)
        yield usage_event(response) if response["usage"]
        message = response.fetch("choices", [{}]).first.fetch("message", {})
        content = message.fetch("content", "").to_s
        yield type: "message_delta", delta: content unless content.empty?
        tool_calls = Array(message["tool_calls"]).map do |tool_call|
          function = tool_call.fetch("function", {})
          ToolCall.new(
            id: tool_call.fetch("id"),
            name: function.fetch("name"),
            raw_arguments: function["arguments"],
            arguments: parse_arguments(function["arguments"])
          )
        end
        yield type: "message_end", tool_calls: tool_calls
      end

      def usage_event(chunk)
        { type: "usage", usage: normalize_usage(chunk.fetch("usage")) }
      end

      def normalize_usage(usage)
        {
          "input_tokens" => usage["prompt_tokens"],
          "output_tokens" => usage["completion_tokens"],
          "total_tokens" => usage["total_tokens"],
          "raw" => usage
        }.compact
      end

      def openai_messages(messages, system_prompt)
        output = []
        output << { role: "system", content: system_prompt } unless system_prompt.to_s.empty?
        messages.each do |message|
          output << openai_message(message)
        end
        output
      end

      def openai_message(message)
        case message.role
        when "assistant"
          output = {
            role: "assistant",
            content: message.content
          }
          output[:tool_calls] = message.tool_calls.map { |tool_call| openai_tool_call(tool_call) } unless message.tool_calls.empty?
          output
        when "tool"
          {
            role: "tool",
            content: message.content,
            tool_call_id: message.tool_call_id
          }.compact
        else
          { role: message.role, content: message.content }
        end
      end

      def openai_tool_call(tool_call)
        {
          id: tool_call.id,
          type: "function",
          function: {
            name: tool_call.name,
            arguments: JSON.generate(tool_call.arguments)
          }
        }
      end

      def openai_tools(tools)
        tools.map do |tool|
          {
            type: "function",
            function: {
              name: tool.name,
              description: tool.description,
              parameters: tool.schema
            }
          }
        end
      end

      def build_tool_call(builder)
        raw_arguments = builder.fetch(:raw_arguments)
        ToolCall.new(
          id: builder.fetch(:id),
          name: builder.fetch(:name),
          raw_arguments: raw_arguments,
          arguments: parse_arguments(raw_arguments)
        )
      end

      def parse_arguments(raw_arguments)
        return {} if raw_arguments.to_s.empty?

        JSON.parse(raw_arguments)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
