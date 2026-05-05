# frozen_string_literal: true

module Kreator
  module Providers
    class Anthropic < Base
      DEFAULT_BASE_URL = "https://api.anthropic.com/v1"
      DEFAULT_VERSION = "2023-06-01"

      def initialize(api_key: ENV["ANTHROPIC_API_KEY"], base_url: ENV.fetch("ANTHROPIC_BASE_URL", DEFAULT_BASE_URL))
        raise Error, "ANTHROPIC_API_KEY is required for the anthropic provider" if api_key.to_s.empty?

        super(api_key: api_key, base_url: base_url, name: "anthropic")
      end

      def stream(messages:, tools:, system_prompt:, model:, signal:)
        body = {
          model: model,
          stream: true,
          max_tokens: 4096,
          system: system_prompt,
          messages: anthropic_messages(messages),
          tools: anthropic_tools(tools)
        }.compact

        content_blocks = {}

        producer = lambda do |push_chunk|
          post_json_stream(
            "messages",
            body,
            headers: {
              "x-api-key" => api_key,
              "anthropic-version" => DEFAULT_VERSION
            }
          ) do |chunk|
            break if signal&.respond_to?(:aborted?) && signal.aborted?

            push_chunk.call(chunk)
          end
        end

        parse_sse_stream(producer) do |data|
          chunk = JSON.parse(data)

          case chunk["type"]
          when "message_start"
            yield type: "message_start", role: "assistant"
          when "content_block_start"
            index = chunk.fetch("index")
            content_blocks[index] = chunk.fetch("content_block", {})
            if content_blocks[index]["type"] == "tool_use"
              yield type: "tool_start", tool_call: anthropic_tool_call(content_blocks[index])
            end
          when "content_block_delta"
            index = chunk.fetch("index")
            delta = chunk.fetch("delta", {})
            if delta["type"] == "text_delta"
              yield type: "message_delta", delta: delta.fetch("text", "")
            elsif delta["type"] == "input_json_delta"
              content_blocks[index]["partial_json"] ||= +""
              content_blocks[index]["partial_json"] << delta.fetch("partial_json", "")
              yield type: "tool_update", index: index, delta: delta
            end
          when "message_stop"
            tool_calls = content_blocks.values.filter_map do |block|
              next unless block["type"] == "tool_use"

              anthropic_tool_call(block)
            end
            yield type: "message_end", tool_calls: tool_calls
          end
        end
      end

      private

      def anthropic_messages(messages)
        messages.reject { |message| message.role == "system" }.map do |message|
          if message.role == "tool"
            {
              role: "user",
              content: [
                {
                  type: "tool_result",
                  tool_use_id: message.tool_call_id,
                  content: message.content
                }
              ]
            }
          else
            { role: message.role, content: message.content }
          end
        end
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
