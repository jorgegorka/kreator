# frozen_string_literal: true

require "json"

module Kreator
  class RPCServer
    attr_reader :provider_builder, :provider_name, :model, :tools, :context, :session_manager, :session

    def initialize(provider_builder:, provider_name:, model:, tools:, context:, session_manager:, session:, stdin:, stdout:)
      @provider_builder = provider_builder
      @provider_name = provider_name
      @model = model
      @tools = tools
      @context = context
      @session_manager = session_manager
      @session = session
      @stdin = stdin
      @stdout = stdout
      @messages = session&.messages || []
    end

    def run
      @stdin.each_line do |line|
        line = line.strip
        next if line.empty?

        handle_line(line)
      end
      0
    end

    private

    def handle_line(line)
      command = JSON.parse(line)
      dispatch(command)
    rescue JSON::ParserError => error
      write_response(nil, false, error: error_hash(error))
    rescue StandardError => error
      write_response(command_id(command), false, error: error_hash(error))
    end

    def dispatch(command)
      case command.fetch("command", command["method"])
      when "prompt"
        handle_prompt(command)
      when "abort"
        write_response(command_id(command), true, state: state.merge("status" => "idle"))
      when "get_state"
        write_response(command_id(command), true, state: state)
      when "get_messages"
        write_response(command_id(command), true, messages: messages.map(&:to_h))
      when "new_session"
        @session = session_manager.create(cwd: command.fetch("cwd", Dir.pwd))
        @messages = []
        write_response(command_id(command), true, session: session_payload)
      when "set_model"
        @model = command.fetch("model")
        @provider_name = command.fetch("provider", provider_name)
        session&.append_model_change(provider: provider_name, model: model)
        write_response(command_id(command), true, state: state)
      else
        raise ArgumentError, "unknown RPC command: #{command.fetch("command", command["method"]).inspect}"
      end
    end

    def handle_prompt(command)
      prompt = command.fetch("prompt")
      provider = provider_builder.call(command.fetch("provider", provider_name))
      command_model = command.fetch("model", model)
      event_bus = EventBus.new
      event_bus.subscribe do |event|
        write_event(command_id(command), event)
      end

      previous_message_count = messages.length
      agent = AgentLoop.new(provider: provider, event_bus: event_bus, model: command_model, tools: tools, context: context)
      final_message = agent.run(prompt: prompt, messages: messages)
      new_messages = agent.last_messages.drop(previous_message_count)
      persist_messages(new_messages)
      @messages = agent.last_messages

      write_response(
        command_id(command),
        true,
        message: final_message.to_h,
        messages: new_messages.map(&:to_h),
        session: session_payload,
        usage: nil
      )
    end

    def messages
      session ? session.messages : @messages
    end

    def persist_messages(new_messages)
      if session
        new_messages.each { |message| session.append_message(message) }
      else
        @messages.concat(new_messages)
      end
    end

    def state
      {
        "provider" => provider_name,
        "model" => model,
        "session" => session_payload,
        "message_count" => messages.length
      }
    end

    def session_payload
      return nil unless session

      {
        "id" => session.id,
        "path" => session.path,
        "cwd" => session.cwd
      }
    end

    def write_event(id, event)
      write_json("type" => "event", "id" => id, "event" => stringify_keys(event))
    end

    def write_response(id, ok, payload = {})
      write_json({ "type" => "response", "id" => id, "ok" => ok }.merge(stringify_keys(payload)))
    end

    def write_json(payload)
      @stdout.puts JSON.generate(payload)
      @stdout.flush if @stdout.respond_to?(:flush)
    end

    def command_id(command)
      command && command["id"]
    end

    def error_hash(error)
      { "class" => error.class.name, "message" => error.message }
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, inner), hash| hash[key.to_s] = stringify_keys(inner) }
      when Array
        value.map { |inner| stringify_keys(inner) }
      else
        value
      end
    end
  end
end
