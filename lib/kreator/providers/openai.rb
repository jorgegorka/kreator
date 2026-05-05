# frozen_string_literal: true

module Kreator
  module Providers
    class OpenAI < Base
      DEFAULT_BASE_URL = "https://api.openai.com/v1"

      def initialize(api_key: ENV.fetch("OPENAI_API_KEY", nil), base_url: ENV.fetch("OPENAI_BASE_URL", DEFAULT_BASE_URL), max_retries: DEFAULT_MAX_RETRIES)
        raise Error, "OPENAI_API_KEY is required for the openai provider" if api_key.to_s.empty?

        super(api_key: api_key, base_url: base_url, name: "openai", max_retries: max_retries)
      end

      def stream(messages:, tools:, system_prompt:, model:, signal:, &)
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
          when /4\.1/, /4o/
            128_000
          end

        super.merge(
          "vision" => model.to_s.match?(/4o|4\.1/),
          "reasoning" => model.to_s.match?(/o[134]|reasoning/),
          "context_window" => context_window
        )
      end

      private

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
          post_json_stream("chat/completions", body, headers: { "Authorization" => "Bearer #{api_key}" }) do |chunk|
            break if signal.respond_to?(:aborted?) && signal.aborted?

            push_chunk.call(chunk)
          end
        end
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
        response = post_json("chat/completions", body, headers: { "Authorization" => "Bearer #{api_key}" })
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
