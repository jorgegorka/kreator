# frozen_string_literal: true

require "json"

module Kreator
  class RPCServer
    attr_reader :provider_builder, :provider_name, :model, :tools, :context, :session_manager, :session, :resources

    Config = Struct.new(
      :provider_builder,
      :provider_name,
      :model,
      :tools,
      :context,
      :session_manager,
      :session,
      :stdin,
      :stdout,
      :resources,
      :compact_threshold,
      keyword_init: true
    )
    RPC_COMMANDS = {
      "prompt" => :handle_prompt,
      "abort" => :handle_abort_command,
      "get_state" => :handle_get_state_command,
      "get_messages" => :handle_get_messages_command,
      "search_sessions" => :handle_search_sessions_command,
      "label_session" => :handle_label_session_command,
      "export_session" => :handle_export_session_command,
      "cleanup_sessions" => :handle_cleanup_sessions_command,
      "get_resources" => :handle_get_resources_command,
      "plugin_list" => :handle_plugin_list_command,
      "plugin_validate" => :handle_plugin_validate_command,
      "plugin_install" => :handle_plugin_install_command,
      "plugin_update" => :handle_plugin_update_command,
      "plugin_remove" => :handle_plugin_remove_command,
      "list_branches" => :handle_list_branches_command,
      "fork_session" => :handle_fork_session_command,
      "new_session" => :handle_new_session_command,
      "set_model" => :handle_set_model_command
    }.freeze

    def initialize(config = nil, **)
      config ||= Config.new(**)
      @provider_builder = config.provider_builder
      @provider_name = config.provider_name
      @model = config.model
      @tools = config.tools
      @context = config.context
      @session_manager = config.session_manager
      @session = config.session
      @stdin = config.stdin
      @stdout = config.stdout
      @resources = config.resources || Resources.new
      @compact_threshold = config.compact_threshold
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
    rescue JSON::ParserError => e
      write_response(nil, false, error: error_hash(e))
    rescue StandardError => e
      write_response(command_id(command), false, error: error_hash(e))
    end

    def dispatch(command)
      name = command_name(command)
      handler = RPC_COMMANDS[name]
      raise ArgumentError, "unknown RPC command: #{name.inspect}" unless handler

      send(handler, command)
    end

    def command_name(command)
      command.fetch("command", command["method"])
    end

    def handle_abort_command(command)
      write_response(command_id(command), true, state: state.merge("status" => "idle"))
    end

    def handle_get_state_command(command)
      write_response(command_id(command), true, state: state)
    end

    def handle_get_messages_command(command)
      write_response(command_id(command), true, messages: messages.map(&:to_h))
    end

    def handle_search_sessions_command(command)
      write_response(
        command_id(command),
        true,
        sessions: session_manager.search(query: command.fetch("query"), cwd: command.fetch("cwd", Dir.pwd))
      )
    end

    def handle_label_session_command(command)
      @session = session_manager.label(path: command_session_path(command), label: command.fetch("label"))
      write_response(command_id(command), true, session: session_payload)
    end

    def handle_export_session_command(command)
      write_response(
        command_id(command),
        true,
        content: session_manager.export(path: command_session_path(command), format: command.fetch("format", "json"))
      )
    end

    def handle_cleanup_sessions_command(command)
      deleted = session_manager.cleanup(cwd: command.fetch("cwd", Dir.pwd), empty: command.fetch("empty", false), failed: command.fetch("failed", false))
      write_response(command_id(command), true, deleted: deleted)
    end

    def handle_get_resources_command(command)
      write_response(command_id(command), true, resources: resource_payload)
    end

    def handle_plugin_list_command(command)
      write_response(command_id(command), true, plugins: plugin_manager.plugins.map { |plugin| plugin_payload(plugin) })
    end

    def handle_plugin_validate_command(command)
      write_response(command_id(command), true, validation: plugin_manager.validate(command.fetch("plugin")))
    end

    def handle_plugin_install_command(command)
      plugin = plugin_manager.install(path: command.fetch("path"), name: command["name"])
      write_response(command_id(command), true, plugin: plugin_payload(plugin))
    end

    def handle_plugin_update_command(command)
      plugin = plugin_manager.update(name: command.fetch("name"), path: command.fetch("path"))
      write_response(command_id(command), true, plugin: plugin_payload(plugin))
    end

    def handle_plugin_remove_command(command)
      plugin_manager.remove(command.fetch("name"))
      write_response(command_id(command), true, removed: command.fetch("name"))
    end

    def handle_list_branches_command(command)
      write_response(command_id(command), true, branches: branches_for(command))
    end

    def handle_fork_session_command(command)
      @session = session_manager.fork(path: command.fetch("session", session&.path), entry_index: command["entry_index"])
      @messages = session.messages
      write_response(command_id(command), true, session: session_payload)
    end

    def handle_new_session_command(command)
      @session = session_manager.create(cwd: command.fetch("cwd", Dir.pwd))
      @messages = []
      write_response(command_id(command), true, session: session_payload)
    end

    def handle_set_model_command(command)
      @model = command.fetch("model")
      @provider_name = command.fetch("provider", provider_name)
      session&.append_model_change(provider: provider_name, model: model)
      write_response(command_id(command), true, state: state)
    end

    def command_session_path(command)
      target = command.fetch("session", session&.path)
      raise ArgumentError, "session is required" unless target

      target
    end

    def handle_prompt(command)
      prompt = materialize_prompt(command.fetch("prompt"), command["template"])
      provider = provider_builder.call(command.fetch("provider", provider_name))
      command_model = command.fetch("model", model)
      event_bus = EventBus.new
      event_bus.subscribe do |event|
        write_event(command_id(command), event)
      end

      maybe_compact_session
      previous_message_count = messages.length
      agent = AgentLoop.new(
        provider: provider,
        event_bus: event_bus,
        system_prompt: resources.system_prompt(base_prompt: AgentLoop::DEFAULT_SYSTEM_PROMPT, prompt: prompt),
        model: command_model,
        tools: tools,
        context: context
      )
      final_message = agent.run(prompt: prompt, messages: messages)
      new_messages = agent.last_messages.drop(previous_message_count)
      persist_messages(new_messages)
      session&.append_session_info("usage" => agent.last_usage) if agent.last_usage
      @messages = agent.last_messages

      write_response(
        command_id(command),
        true,
        message: final_message.to_h,
        messages: new_messages.map(&:to_h),
        session: session_payload,
        usage: agent.last_usage
      )
    end

    def messages
      return @messages unless session

      session.compaction_entries.empty? ? session.messages : session.compacted_messages
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
        "capabilities" => provider_capabilities,
        "session" => session_payload,
        "message_count" => messages.length,
        "resources" => resource_counts
      }
    end

    def session_payload
      return nil unless session

      {
        "id" => session.id,
        "path" => session.path,
        "cwd" => session.cwd,
        "labels" => session.labels
      }
    end

    def write_event(id, event)
      write_json("type" => "event", "id" => id, "event" => stringify_keys(event))
    end

    def write_response(id, success, payload = {})
      write_json({ "type" => "response", "id" => id, "ok" => success }.merge(stringify_keys(payload)))
    end

    def write_json(payload)
      @stdout.puts JSON.generate(payload)
      @stdout.flush if @stdout.respond_to?(:flush)
    end

    def command_id(command)
      command && command["id"]
    end

    def error_hash(error)
      return error.to_h if error.respond_to?(:to_h) && (error.is_a?(Providers::Error) || error.is_a?(ToolError))

      { "class" => error.class.name, "message" => error.message, "code" => "runtime_error" }
    end

    def materialize_prompt(prompt, template)
      return prompt unless template

      resources.apply_prompt_template(template, prompt)
    end

    def maybe_compact_session
      return unless session
      return unless session.compaction_entries.empty?
      return unless Compactor.should_compact?(session.messages, threshold: @compact_threshold)

      session.compact!
    end

    def resource_payload
      {
        "project_instructions" => resources.project_instructions.map { |file| resource_file_payload(file) },
        "prompt_templates" => resources.prompt_templates.map { |file| resource_file_payload(file) },
        "skills" => resources.skills.map { |file| resource_file_payload(file) },
        "plugins" => resources.plugins.map { |plugin| plugin_payload(plugin) },
        "plugin_tools" => resources.plugin_tools.map(&:to_h)
      }
    end

    def resource_counts
      {
        "project_instructions" => resources.project_instructions.length,
        "prompt_templates" => resources.prompt_templates.length,
        "skills" => resources.skills.length,
        "plugins" => resources.plugins.length,
        "plugin_tools" => resources.plugin_tools.length
      }
    end

    def resource_file_payload(file)
      { "name" => file.name, "path" => file.path }
    end

    def plugin_manager
      resources.plugin_manager
    end

    def plugin_payload(plugin)
      plugin.to_h.merge(
        "tools" => PluginToolLoader.new.load_tools([plugin]).map(&:to_h)
      )
    rescue StandardError => e
      plugin.to_h.merge("tool_errors" => [e.message])
    end

    def branches_for(command)
      parent_id = command.fetch("parent_id", session&.id)
      raise ArgumentError, "parent_id is required without an active session" unless parent_id

      session_manager.branches(parent_id: parent_id)
    end

    def provider_capabilities
      provider_builder.call(provider_name).capabilities(model)
    rescue StandardError
      nil
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
