# frozen_string_literal: true

module Kreator
  class AgentLoop
    DEFAULT_SYSTEM_PROMPT = "You are Kreator, a concise and practical coding assistant."
    DEFAULT_MAX_TOOL_ITERATIONS = 16

    attr_reader :provider, :event_bus, :system_prompt, :model, :tools, :tool_registry, :context, :last_messages, :last_usage

    def initialize(options = {})
      @provider = options.fetch(:provider)
      @event_bus = options.fetch(:event_bus, EventBus.new)
      @system_prompt = options.fetch(:system_prompt, DEFAULT_SYSTEM_PROMPT)
      @model = options.fetch(:model, nil)
      @tool_registry = normalize_tools(options.fetch(:tools, nil))
      @tools = @tool_registry.to_a
      @context = options.fetch(:context, ToolContext.new)
      @max_tool_iterations = options.fetch(:max_tool_iterations, DEFAULT_MAX_TOOL_ITERATIONS)
      @last_usage = nil
    end

    def run(prompt:, messages: [], signal: nil)
      normalized_messages = messages.map { |message| normalize_message(message) }
      normalized_messages << Message.user(prompt)

      @last_usage = nil
      publish("agent_start", model: model, provider: provider_name, capabilities: provider_capabilities)

      final_message = run_until_complete(normalized_messages, signal: signal)

      publish("turn_end", message: final_message.to_h)
      publish("agent_end", message: final_message.to_h)
      @last_messages = normalized_messages
      final_message
    rescue StandardError => e
      publish("agent_end", error: error_hash(e))
      raise
    end

    private

    def run_until_complete(messages, signal:)
      iterations = 0

      loop do
        ensure_not_cancelled!(signal)
        iterations += 1
        raise Error, "tool iteration limit exceeded" if iterations > @max_tool_iterations

        final_message = run_turn(messages, signal: signal)
        ensure_not_cancelled!(signal)
        messages << final_message
        return final_message if final_message.tool_calls.empty?

        append_tool_results(messages, final_message.tool_calls, signal: signal)
        ensure_not_cancelled!(signal)
      end
    end

    def run_turn(messages, signal:)
      state = { content: +"", tool_calls: [] }

      publish("turn_start", messages: messages.map(&:to_h))
      stream_provider(messages, signal: signal) do |event|
        event = update_turn_state(state, event)
        publish(event.delete(:type), event)
      end

      Message.assistant(state.fetch(:content), tool_calls: state.fetch(:tool_calls))
    end

    def stream_provider(messages, signal:, &)
      provider.stream(
        messages: messages.dup,
        tools: tools,
        system_prompt: system_prompt,
        model: model,
        signal: signal,
        &
      )
    end

    def update_turn_state(state, event)
      event = normalize_event(event)

      case event.fetch(:type)
      when "message_delta"
        state.fetch(:content) << event.fetch(:delta, "").to_s
      when "usage"
        @last_usage = merge_usage(@last_usage, event.fetch(:usage, {}))
      when "message_end"
        apply_message_end(state, event)
      when "tool_start"
        state.fetch(:tool_calls) << normalize_tool_call(event[:tool_call]) if event[:tool_call]
      end

      event
    end

    def apply_message_end(state, event)
      if event[:message]
        message = normalize_message(event[:message])
        state[:content] = message.content.dup
        state[:tool_calls] = message.tool_calls
      elsif event[:tool_calls]
        state[:tool_calls] = event[:tool_calls].map { |call| normalize_tool_call(call) }
      end
    end

    def append_tool_results(messages, tool_calls, signal:)
      tool_calls.each do |tool_call|
        publish("tool_start", tool_call: tool_call.to_h, execution: true)
        result = tool_registry.call(tool_call, context: context, signal: signal)
        publish("tool_end", tool_call: tool_call.to_h, result: result.to_h, execution: true)
        messages << result.to_message
      end
    end

    def provider_name
      provider.respond_to?(:name) ? provider.name : provider.class.name
    end

    def provider_capabilities
      return nil unless provider.respond_to?(:capabilities)

      provider.capabilities(model)
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

    def ensure_not_cancelled!(signal)
      return unless signal.respond_to?(:aborted?) && signal.aborted?

      raise ToolCancellationError
    end

    def merge_usage(current, incoming)
      incoming = stringify_keys(incoming || {})
      return incoming if current.nil?

      merged = current.merge(incoming)
      %w[input_tokens output_tokens total_tokens].each do |key|
        values = [current[key], incoming[key]].compact
        merged[key] = values.max unless values.empty?
      end
      merged
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(key, value), output| output[key.to_s] = value }
    end

    def error_hash(error)
      return error.to_h if error.respond_to?(:to_h) && error.is_a?(Providers::Error)

      { "class" => error.class.name, "message" => error.message, "code" => "runtime_error" }
    end

    class Error < StandardError; end
  end
end
