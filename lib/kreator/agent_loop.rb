# frozen_string_literal: true

module Kreator
  class AgentLoop
    DEFAULT_SYSTEM_PROMPT = "You are Kreator, a concise and practical coding assistant."
    DEFAULT_MAX_TOOL_ITERATIONS = 16

    attr_reader :provider, :event_bus, :system_prompt, :model, :tools, :tool_registry, :context, :last_messages

    def initialize(
      provider:,
      event_bus: EventBus.new,
      system_prompt: DEFAULT_SYSTEM_PROMPT,
      model: nil,
      tools: nil,
      context: ToolContext.new,
      max_tool_iterations: DEFAULT_MAX_TOOL_ITERATIONS
    )
      @provider = provider
      @event_bus = event_bus
      @system_prompt = system_prompt
      @model = model
      @tool_registry = normalize_tools(tools)
      @tools = @tool_registry.to_a
      @context = context
      @max_tool_iterations = max_tool_iterations
    end

    def run(prompt:, messages: [], signal: nil)
      normalized_messages = messages.map { |message| normalize_message(message) }
      normalized_messages << Message.user(prompt)
      final_message = nil
      iterations = 0

      publish("agent_start", model: model, provider: provider_name)

      loop do
        iterations += 1
        raise Error, "tool iteration limit exceeded" if iterations > @max_tool_iterations

        assistant_content = +""
        assistant_tool_calls = []

        publish("turn_start", messages: normalized_messages.map(&:to_h))

        provider.stream(
          messages: normalized_messages.dup,
          tools: tools,
          system_prompt: system_prompt,
          model: model,
          signal: signal
        ) do |event|
          event = normalize_event(event)

          case event.fetch(:type)
          when "message_delta"
            assistant_content << event.fetch(:delta, "").to_s
          when "message_end"
            if event[:message]
              message = normalize_message(event[:message])
              assistant_content = message.content.dup
              assistant_tool_calls = message.tool_calls
            elsif event[:tool_calls]
              assistant_tool_calls = event[:tool_calls].map { |call| normalize_tool_call(call) }
            end
          when "tool_start"
            assistant_tool_calls << normalize_tool_call(event[:tool_call]) if event[:tool_call]
          end

          publish(event.delete(:type), event)
        end

        final_message = Message.assistant(assistant_content, tool_calls: assistant_tool_calls)
        normalized_messages << final_message
        break if assistant_tool_calls.empty?

        assistant_tool_calls.each do |tool_call|
          publish("tool_start", tool_call: tool_call.to_h, execution: true)
          result = tool_registry.call(tool_call, context: context, signal: signal)
          publish("tool_end", tool_call: tool_call.to_h, result: result.to_h, execution: true)
          normalized_messages << result.to_message
        end
      end

      publish("turn_end", message: final_message.to_h)
      publish("agent_end", message: final_message.to_h)
      @last_messages = normalized_messages
      final_message
    rescue StandardError => error
      publish("agent_end", error: { "class" => error.class.name, "message" => error.message })
      raise
    end

    private

    def provider_name
      provider.respond_to?(:name) ? provider.name : provider.class.name
    end

    def normalize_message(message)
      message.is_a?(Message) ? message : Message.from_h(message)
    end

    def normalize_tool_call(tool_call)
      tool_call.is_a?(ToolCall) ? tool_call : ToolCall.from_h(tool_call)
    end

    def normalize_tools(tools)
      return ToolRegistry.default if tools.nil?
      return tools if tools.is_a?(ToolRegistry)

      ToolRegistry.new(tools)
    end

    def normalize_event(event)
      event = event.transform_keys(&:to_sym)
      event[:type] = event.fetch(:type).to_s
      event
    end

    def publish(type, payload = {})
      event_bus.publish(type, payload)
    end

    class Error < StandardError; end
  end
end
