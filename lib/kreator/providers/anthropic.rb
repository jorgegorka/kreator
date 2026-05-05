# frozen_string_literal: true

module Kreator
  module Providers
    class Anthropic < Base
      DEFAULT_BASE_URL = "https://api.anthropic.com/v1"
      DEFAULT_VERSION = "2023-06-01"

      def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY", nil), base_url: ENV.fetch("ANTHROPIC_BASE_URL", DEFAULT_BASE_URL), max_retries: DEFAULT_MAX_RETRIES)
        raise Error, "ANTHROPIC_API_KEY is required for the anthropic provider" if api_key.to_s.empty?

        super(api_key: api_key, base_url: base_url, name: "anthropic", max_retries: max_retries)
      end

      def stream(messages:, tools:, system_prompt:, model:, signal:, &)
        body = anthropic_stream_body(messages, tools, system_prompt, model)
        stream_state = {
          content_blocks: {},
          emitted_model_output: false
        }

        begin
          stream_anthropic_events(body, signal, stream_state, &)
        rescue Providers::Error
          raise if stream_state.fetch(:emitted_model_output)

          complete_once(body.merge(stream: false), &)
        end
      end

      def capabilities(model)
        super.merge(
          "vision" => model.to_s.match?(/claude/),
          "reasoning" => model.to_s.match?(/opus|sonnet-4|3-7/),
          "context_window" => 200_000
        )
      end

      private

      def anthropic_stream_body(messages, tools, system_prompt, model)
        {
          model: model,
          stream: true,
          max_tokens: 4096,
          system: system_prompt,
          messages: anthropic_messages(messages),
          tools: anthropic_tools(tools)
        }.compact
      end

      def stream_anthropic_events(body, signal, stream_state, &block)
        parse_sse_stream(anthropic_stream_producer(body, signal)) do |data|
          handle_anthropic_event(JSON.parse(data), stream_state, &block)
        end
      end

      def anthropic_stream_producer(body, signal)
        lambda do |push_chunk|
          post_json_stream("messages", body, headers: anthropic_headers) do |chunk|
            break if signal.respond_to?(:aborted?) && signal.aborted?

            push_chunk.call(chunk)
          end
        end
      end

      def anthropic_headers
        {
          "x-api-key" => api_key,
          "anthropic-version" => DEFAULT_VERSION
        }
      end

      def handle_anthropic_event(chunk, stream_state, &block)
        block.call(usage_event(chunk)) if chunk["usage"]

        case chunk["type"]
        when "message_start"
          block.call(type: "message_start", role: "assistant")
        when "content_block_start"
          handle_anthropic_content_block_start(chunk, stream_state, &block)
        when "content_block_delta"
          handle_anthropic_content_block_delta(chunk, stream_state, &block)
        when "message_stop"
          block.call(type: "message_end", tool_calls: anthropic_tool_calls(stream_state))
        end
      end

      def handle_anthropic_content_block_start(chunk, stream_state, &block)
        index = chunk.fetch("index")
        content_block = chunk.fetch("content_block", {})
        stream_state.fetch(:content_blocks)[index] = content_block
        return unless content_block["type"] == "tool_use"

        stream_state[:emitted_model_output] = true
        block.call(type: "tool_start", tool_call: anthropic_tool_call(content_block))
      end

      def handle_anthropic_content_block_delta(chunk, stream_state, &block)
        index = chunk.fetch("index")
        delta = chunk.fetch("delta", {})

        case delta["type"]
        when "text_delta"
          stream_state[:emitted_model_output] = true
          block.call(type: "message_delta", delta: delta.fetch("text", ""))
        when "input_json_delta"
          append_anthropic_partial_json(stream_state.fetch(:content_blocks), index, delta)
          stream_state[:emitted_model_output] = true
          block.call(type: "tool_update", index: index, delta: delta)
        end
      end

      def append_anthropic_partial_json(content_blocks, index, delta)
        content_blocks[index]["partial_json"] ||= +""
        content_blocks[index]["partial_json"] << delta.fetch("partial_json", "")
      end

      def anthropic_tool_calls(stream_state)
        stream_state.fetch(:content_blocks).values.filter_map do |block|
          next unless block["type"] == "tool_use"

          anthropic_tool_call(block)
        end
      end

      def complete_once(body)
        response = post_json("messages", body, headers: anthropic_headers)
        yield type: "message_start", role: "assistant"
        yield usage_event(response) if response["usage"]
        content = +""
        tool_calls = []
        Array(response["content"]).each do |block|
          case block["type"]
          when "text"
            content << block.fetch("text", "")
          when "tool_use"
            tool_calls << anthropic_tool_call(block)
          end
        end
        yield type: "message_delta", delta: content unless content.empty?
        yield type: "message_end", tool_calls: tool_calls
      end

      def usage_event(chunk)
        usage = chunk.fetch("usage")
        {
          type: "usage",
          usage: {
            "input_tokens" => usage["input_tokens"],
            "output_tokens" => usage["output_tokens"],
            "total_tokens" => [usage["input_tokens"], usage["output_tokens"]].compact.sum,
            "raw" => usage
          }.compact
        }
      end

      def anthropic_messages(messages)
        messages.reject { |message| message.role == "system" }.each_with_object([]) do |message, output|
          append_anthropic_message(output, message)
        end
      end

      def append_anthropic_message(output, message)
        case message.role
        when "tool"
          append_anthropic_tool_result(output, message)
        when "assistant"
          output << anthropic_assistant_message(message)
        else
          output << { role: message.role, content: message.content }
        end
      end

      def append_anthropic_tool_result(output, message)
        tool_result = {
          type: "tool_result",
          tool_use_id: message.tool_call_id,
          content: message.content
        }

        if output.last&.fetch(:role, nil) == "user" && output.last.fetch(:content).is_a?(Array)
          output.last.fetch(:content) << tool_result
        else
          output << { role: "user", content: [tool_result] }
        end
      end

      def anthropic_assistant_message(message)
        return { role: "assistant", content: message.content } if message.tool_calls.empty?

        content = []
        content << { type: "text", text: message.content } unless message.content.empty?
        message.tool_calls.each do |tool_call|
          content << {
            type: "tool_use",
            id: tool_call.id,
            name: tool_call.name,
            input: tool_call.arguments
          }
        end
        { role: "assistant", content: content }
      end

      def anthropic_tools(tools)
        tools.map do |tool|
          {
            name: tool.name,
            description: tool.description,
            input_schema: tool.schema
          }
        end
      end

      def anthropic_tool_call(block)
        raw_arguments = block["partial_json"]
        arguments = block["input"] || parse_arguments(raw_arguments)
        ToolCall.new(
          id: block.fetch("id"),
          name: block.fetch("name"),
          arguments: arguments,
          raw_arguments: raw_arguments
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
