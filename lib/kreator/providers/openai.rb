# frozen_string_literal: true

module Kreator
  module Providers
    class OpenAI < Base
      DEFAULT_BASE_URL = "https://api.openai.com/v1"

      def initialize(api_key: ENV["OPENAI_API_KEY"], base_url: ENV.fetch("OPENAI_BASE_URL", DEFAULT_BASE_URL))
        raise Error, "OPENAI_API_KEY is required for the openai provider" if api_key.to_s.empty?

        super(api_key: api_key, base_url: base_url, name: "openai")
      end

      def stream(messages:, tools:, system_prompt:, model:, signal:)
        yield type: "message_start", role: "assistant"

        body = {
          model: model,
          stream: true,
          messages: openai_messages(messages, system_prompt),
          tools: openai_tools(tools)
        }.compact

        tool_call_builders = {}

        producer = lambda do |push_chunk|
          post_json_stream("chat/completions", body, headers: { "Authorization" => "Bearer #{api_key}" }) do |chunk|
            break if signal&.respond_to?(:aborted?) && signal.aborted?

            push_chunk.call(chunk)
          end
        end

        parse_sse_stream(producer) do |data|
          break if data == "[DONE]"

          chunk = JSON.parse(data)
          choice = chunk.fetch("choices", [{}]).first
          delta = choice.fetch("delta", {})

          if delta["content"]
            yield type: "message_delta", delta: delta["content"]
          end

          Array(delta["tool_calls"]).each do |tool_call_delta|
            index = tool_call_delta.fetch("index")
            builder = tool_call_builders[index] ||= {
              id: nil,
              name: nil,
              raw_arguments: +""
            }
            builder[:id] = tool_call_delta["id"] if tool_call_delta["id"]
            function = tool_call_delta["function"] || {}
            builder[:name] = function["name"] if function["name"]
            builder[:raw_arguments] << function["arguments"].to_s if function["arguments"]
            yield type: "tool_update", index: index, delta: tool_call_delta
          end
        end

        tool_calls = tool_call_builders.values.map { |builder| build_tool_call(builder) }
        yield type: "message_end", tool_calls: tool_calls
      end

      private

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
