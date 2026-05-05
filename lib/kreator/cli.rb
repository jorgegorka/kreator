# frozen_string_literal: true

require "json"
require "optparse"

module Kreator
  class CLI
    DEFAULT_PROVIDER = "openai"
    DEFAULT_MODEL = "gpt-4o-mini"
    SESSION_COMMANDS = {
      list_sessions: :list_sessions_payload,
      search_sessions: :search_sessions_payload,
      label_session: :label_session_payload,
      export_session: :export_session_payload,
      cleanup_empty_sessions: :cleanup_empty_sessions_payload
    }.freeze
    PLUGIN_COMMANDS = {
      "list" => :plugin_list_payload,
      "available" => :plugin_available_payload,
      "validate" => :plugin_validate_payload,
      "install" => :plugin_install_payload,
      "update" => :plugin_update_payload,
      "remove" => :plugin_remove_payload
    }.freeze
    PLUGIN_RENDERERS = {
      "plugins" => :render_plugin_list,
      "validation" => :render_plugin_validation,
      "plugin" => :render_single_plugin,
      "removed" => :render_removed_plugin
    }.freeze

    def initialize(argv, stdout:, stderr:, stdin: $stdin, provider_builder: Providers.method(:build))
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @provider_builder = provider_builder
      @options = {
        provider: ENV.fetch("KREATOR_PROVIDER", DEFAULT_PROVIDER),
        model: ENV.fetch("KREATOR_MODEL", DEFAULT_MODEL),
        tools: nil,
        no_tools: false,
        timeout: ToolContext::DEFAULT_BASH_TIMEOUT,
        session: nil,
        continue: false,
        no_session: false,
        session_dir: SessionManager::DEFAULT_SESSION_DIR,
        resource_home: ENV.fetch("KREATOR_HOME", Resources::DEFAULT_HOME),
        plugins_enabled: true,
        plugins: nil,
        prompt_template: nil,
        compact_threshold: ENV["KREATOR_COMPACT_THRESHOLD"]&.to_i,
        approval_policy: ENV.fetch("KREATOR_APPROVAL_POLICY", "auto"),
        plugin_approval_policy: ENV.fetch("KREATOR_PLUGIN_TOOL_POLICY", "prompt"),
        allow_paths: nil,
        bash_deny_patterns: [],
        plugin_install_name: nil,
        list_sessions: false,
        search_sessions: nil,
        label_session: nil,
        export_session: nil,
        cleanup_empty_sessions: false,
        json: false,
        rpc: false
      }
    end

    def run
      parser.parse!(@argv)
      return run_rpc if @options.fetch(:rpc)

      command_status = run_option_command
      return command_status if command_status

      prompt = @argv.join(" ").strip
      return handle_missing_prompt if prompt.empty?

      result = run_prompt(prompt)
      emit_prompt_result(result)
      0
    rescue OptionParser::ParseError, ArgumentError, Providers::Error, ToolRegistry::Error, AgentLoop::Error => e
      if @options[:json]
        @stdout.puts JSON.generate("ok" => false, "error" => error_hash(e))
      else
        @stderr.puts "kreator: #{e.message}"
      end
      1
    end

    private

    def run_prompt(prompt)
      provider = @provider_builder.call(@options.fetch(:provider))
      event_bus = EventBus.new
      event_bus.subscribe("message_delta") { |event| @stdout.print event.fetch(:delta) } unless @options.fetch(:json)
      prompt = materialize_prompt(prompt)
      resources = build_resources
      tools = build_tools(resources: resources)
      context = build_context
      session = build_session
      system_prompt = resources.system_prompt(base_prompt: AgentLoop::DEFAULT_SYSTEM_PROMPT, prompt: prompt)
      maybe_compact_session(session)
      persist_model_change(session)
      messages = conversation_messages(session)
      previous_message_count = messages.length
      agent = AgentLoop.new(
        provider: provider,
        event_bus: event_bus,
        system_prompt: system_prompt,
        model: @options.fetch(:model),
        tools: tools,
        context: context
      )
      final_message = agent.run(prompt: prompt, messages: messages)
      new_messages = agent.last_messages.drop(previous_message_count)
      persist_messages(session, new_messages) if session
      persist_usage(session, agent.last_usage) if session && agent.last_usage
      {
        "ok" => true,
        "message" => final_message.to_h,
        "messages" => new_messages.map(&:to_h),
        "tool_calls" => final_message.tool_calls.map(&:to_h),
        "usage" => agent.last_usage,
        "session" => session_payload(session)
      }
    end

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: kreator [options] \"prompt\""

        opts.on("--provider PROVIDER", "Provider to use: openai or anthropic") do |provider|
          @options[:provider] = provider
        end

        opts.on("--model MODEL", "Provider model name") do |model|
          @options[:model] = model
        end

        opts.on("--no-tools", "Disable tool execution") do
          @options[:no_tools] = true
        end

        opts.on("--tools LIST", "Comma-separated tools to enable: read,bash,edit,write") do |list|
          @options[:tools] = list.split(",").map(&:strip).reject(&:empty?)
        end

        opts.on("--timeout SECONDS", Integer, "Default bash timeout in seconds") do |seconds|
          assign_positive_option(:timeout, seconds, "--timeout")
        end

        opts.on("--allow-path PATH", "Allow file tools to access PATH; repeat for multiple paths") do |path|
          @options[:allow_paths] ||= []
          @options[:allow_paths] << path
        end

        opts.on("--deny-bash PATTERN", "Deny bash commands matching a Ruby regular expression") do |pattern|
          @options[:bash_deny_patterns] << pattern
        end

        opts.on("--approval-policy POLICY", "Tool approval policy: auto, prompt, or deny") do |policy|
          @options[:approval_policy] = policy
        end

        opts.on("--plugin-tool-policy POLICY", "Plugin tool approval policy: auto, prompt, or deny") do |policy|
          @options[:plugin_approval_policy] = policy
        end

        opts.on("--ask-permission", "Prompt before write, edit, or bash tool execution") do
          @options[:approval_policy] = "prompt"
        end

        opts.on("--name NAME", "Name to use with plugin install") do |name|
          @options[:plugin_install_name] = name
        end

        opts.on("--no-session", "Disable session persistence") do
          @options[:no_session] = true
        end

        opts.on("--session PATH_OR_ID", "Resume a specific session file or id") do |session|
          @options[:session] = session
        end

        opts.on("--continue", "Resume the most recent session for this directory") do
          @options[:continue] = true
        end

        opts.on("--session-dir PATH", "Session storage directory") do |path|
          @options[:session_dir] = path
        end

        opts.on("--list-sessions", "List sessions for the current directory") do
          @options[:list_sessions] = true
        end

        opts.on("--search-sessions QUERY", "Search sessions for the current directory") do |query|
          @options[:search_sessions] = query
        end

        opts.on("--label-session LABEL", "Append LABEL to --session PATH_OR_ID") do |label|
          @options[:label_session] = label
        end

        opts.on("--export-session FORMAT", "Export --session PATH_OR_ID as json, jsonl, markdown, or plain") do |format|
          @options[:export_session] = format
        end

        opts.on("--cleanup-empty-sessions", "Delete empty sessions for the current directory") do
          @options[:cleanup_empty_sessions] = true
        end

        opts.on("--resource-home PATH", "Resource home for global prompts and skills") do |path|
          @options[:resource_home] = path
        end

        opts.on("--no-plugins", "Disable local resource plugins") do
          @options[:plugins_enabled] = false
        end

        opts.on("--plugin NAME", "Enable only the named plugin; repeat for multiple plugins") do |name|
          @options[:plugins] ||= []
          @options[:plugins] << name
        end

        opts.on("--prompt-template NAME", "Apply a global or project prompt template") do |name|
          @options[:prompt_template] = name
        end

        opts.on("--compact-threshold CHARS", Integer, "Auto-compact sessions above this content size") do |chars|
          assign_positive_option(:compact_threshold, chars, "--compact-threshold")
        end

        opts.on("--json", "Emit final structured JSON instead of streaming text") do
          @options[:json] = true
        end

        opts.on("--rpc", "Run JSONL RPC mode on stdin/stdout") do
          @options[:rpc] = true
        end

        opts.on("-h", "--help", "Print help") do
          @stdout.puts opts
          exit 0
        end
      end
    end

    def assign_positive_option(key, value, name)
      raise OptionParser::InvalidArgument, "#{name} must be positive" unless value.positive?

      @options[key] = value
    end

    def build_tools(resources: nil)
      return ToolRegistry.new if @options.fetch(:no_tools)

      registry = ToolRegistry.default(bash_timeout: @options.fetch(:timeout))
      if @options.fetch(:plugins_enabled)
        (resources || build_resources).plugin_tools.each do |tool|
          registry.register(tool)
        end
      end
      @options[:tools] ? registry.select_names(@options.fetch(:tools)) : registry
    end

    def build_context
      ToolContext.new(
        bash_timeout: @options.fetch(:timeout),
        path_allowlist: @options[:allow_paths],
        bash_deny_patterns: @options.fetch(:bash_deny_patterns),
        approval_policy: @options.fetch(:approval_policy),
        approval_callback: method(:approve_tool?),
        plugin_approval_policy: @options.fetch(:plugin_approval_policy),
        plugin_approval_callback: method(:approve_tool?)
      )
    end

    def build_session
      return nil if @options.fetch(:no_session)
      raise ArgumentError, "--session and --continue cannot be used together" if @options[:session] && @options[:continue]

      manager = SessionManager.new(session_dir: @options.fetch(:session_dir))
      if @options[:session]
        manager.open(path: @options.fetch(:session))
      elsif @options[:continue]
        manager.continue_recent(cwd: Dir.pwd)
      else
        manager.create(cwd: Dir.pwd)
      end
    end

    def persist_messages(session, messages)
      messages.each { |message| session.append_message(message) }
    end

    def run_rpc
      raise ArgumentError, "--rpc does not accept a prompt argument" unless @argv.empty?

      resources = build_resources
      tools = build_tools(resources: resources)
      context = build_context
      session_manager = SessionManager.new(session_dir: @options.fetch(:session_dir))
      session = build_session
      RPCServer.new(
        provider_builder: @provider_builder,
        provider_name: @options.fetch(:provider),
        model: @options.fetch(:model),
        tools: tools,
        context: context,
        session_manager: session_manager,
        session: session,
        resources: resources,
        compact_threshold: @options[:compact_threshold],
        stdin: @stdin,
        stdout: @stdout
      ).run
    end

    def run_interactive
      resources = build_resources
      tools = build_tools(resources: resources)
      context = build_context
      session_manager = SessionManager.new(session_dir: @options.fetch(:session_dir))
      session = build_session
      InteractiveCLI.new(
        provider_builder: @provider_builder,
        provider_name: @options.fetch(:provider),
        model: @options.fetch(:model),
        tools: tools,
        context: context,
        session_manager: session_manager,
        session: session,
        resources: resources,
        compact_threshold: @options[:compact_threshold],
        stdin: @stdin,
        stdout: @stdout,
        stderr: @stderr
      ).run
    end

    def run_option_command
      run_plugin_command || run_session_command
    end

    def handle_missing_prompt
      return run_interactive if interactive_tty? && !@options.fetch(:json)

      @stderr.puts parser
      1
    end

    def emit_prompt_result(result)
      if @options.fetch(:json)
        @stdout.puts JSON.generate(result)
      else
        @stdout.puts
      end
    end

    def interactive_tty?
      @stdin.respond_to?(:tty?) && @stdin.tty? && @stdout.respond_to?(:tty?) && @stdout.tty?
    end

    def session_payload(session)
      return nil unless session

      {
        "id" => session.id,
        "path" => session.path,
        "cwd" => session.cwd,
        "labels" => session.labels
      }
    end

    def error_hash(error)
      return error.to_h if error.respond_to?(:to_h) && (error.is_a?(Providers::Error) || error.is_a?(ToolError))

      { "class" => error.class.name, "message" => error.message, "code" => "runtime_error" }
    end

    def build_resources
      Resources.new(
        cwd: Dir.pwd,
        home_dir: @options.fetch(:resource_home),
        plugins_enabled: @options.fetch(:plugins_enabled),
        plugin_names: @options[:plugins]
      )
    end

    def materialize_prompt(prompt)
      return prompt unless @options[:prompt_template]

      build_resources.apply_prompt_template(@options.fetch(:prompt_template), prompt)
    end

    def conversation_messages(session)
      return [] unless session

      session.compaction_entries.empty? ? session.messages : session.compacted_messages
    end

    def maybe_compact_session(session)
      return unless session
      return unless session.compaction_entries.empty?
      return unless Compactor.should_compact?(session.messages, threshold: @options[:compact_threshold])

      session.compact!
    end

    def persist_usage(session, usage)
      session.append_session_info("usage" => usage)
    end

    def persist_model_change(session)
      session&.append_model_change_unless_current(provider: @options.fetch(:provider), model: @options.fetch(:model))
    end

    def run_session_command
      command = active_session_command
      return nil unless command

      manager = SessionManager.new(session_dir: @options.fetch(:session_dir))
      payload = send(SESSION_COMMANDS.fetch(command), manager)
      return 0 if payload == :streamed

      if @options[:json]
        @stdout.puts JSON.generate({ "ok" => true }.merge(payload))
      else
        @stdout.puts render_session_command(payload)
      end
      0
    end

    def active_session_command
      SESSION_COMMANDS.keys.find { |key| @options[key] }
    end

    def list_sessions_payload(manager)
      { "sessions" => manager.list(cwd: Dir.pwd) }
    end

    def search_sessions_payload(manager)
      { "sessions" => manager.search(query: @options.fetch(:search_sessions), cwd: Dir.pwd) }
    end

    def label_session_payload(manager)
      raise ArgumentError, "--label-session requires --session" unless @options[:session]

      session = manager.label(path: @options.fetch(:session), label: @options.fetch(:label_session))
      { "session" => session_payload(session) }
    end

    def export_session_payload(manager)
      raise ArgumentError, "--export-session requires --session" unless @options[:session]

      @stdout.puts manager.export(path: @options.fetch(:session), format: @options.fetch(:export_session))
      :streamed
    end

    def cleanup_empty_sessions_payload(manager)
      { "deleted" => manager.cleanup(cwd: Dir.pwd, empty: true) }
    end

    def run_plugin_command
      return nil unless @argv.first == "plugin"

      @argv.shift
      command = @argv.shift
      manager = PluginManager.new(cwd: Dir.pwd, home_dir: @options.fetch(:resource_home))
      handler = PLUGIN_COMMANDS[command]
      raise ArgumentError, "unknown plugin command: #{command.inspect}" unless handler

      payload = send(handler, manager)

      if @options[:json]
        @stdout.puts JSON.generate({ "ok" => true }.merge(payload))
      else
        @stdout.puts render_plugin_command(payload)
      end
      0
    end

    def plugin_list_payload(manager)
      { "plugins" => manager.plugins.map { |plugin| plugin_payload(plugin) } }
    end

    def plugin_available_payload(manager)
      { "plugins" => manager.available_plugins.map { |plugin| plugin_payload(plugin) } }
    end

    def plugin_validate_payload(manager)
      { "validation" => manager.validate(plugin_arg(0, "plugin validate requires PATH_OR_NAME")) }
    end

    def plugin_install_payload(manager)
      plugin = manager.install(path: plugin_arg(0, "plugin install requires PATH"), name: @options[:plugin_install_name])
      { "plugin" => plugin_payload(plugin) }
    end

    def plugin_update_payload(manager)
      plugin = manager.update(
        name: plugin_arg(0, "plugin update requires NAME"),
        path: plugin_arg(1, "plugin update requires PATH")
      )
      { "plugin" => plugin_payload(plugin) }
    end

    def plugin_remove_payload(manager)
      name = plugin_arg(0, "plugin remove requires NAME")
      manager.remove(name)
      { "removed" => name }
    end

    def plugin_payload(plugin)
      plugin.to_h.merge(
        "tools" => PluginToolLoader.new.load_tools([plugin]).map(&:to_h)
      )
    rescue StandardError => e
      plugin.to_h.merge("tool_errors" => [e.message])
    end

    def plugin_arg(index, message)
      @argv.fetch(index)
    rescue IndexError
      raise ArgumentError, message
    end

    def render_plugin_command(payload)
      key, renderer = PLUGIN_RENDERERS.find { |payload_key, _| payload[payload_key] }
      return payload.inspect unless key

      send(renderer, payload.fetch(key))
    end

    def render_plugin_list(plugins)
      return "Plugins: none" if plugins.empty?

      plugins.map { |plugin| plugin_line(plugin) }.join("\n")
    end

    def render_plugin_validation(validation)
      status = validation.fetch("ok") ? "ok" : "error"
      errors = validation.fetch("errors", [])
      ["Validation #{status}: #{validation.fetch('plugin').fetch('name')}", *errors].join("\n")
    end

    def render_single_plugin(plugin)
      "Plugin #{plugin.fetch('name')}"
    end

    def render_removed_plugin(name)
      "Removed plugin #{name}"
    end

    def plugin_line(plugin)
      tools = Array(plugin["tools"]).map { |tool| tool.fetch("name", nil) }.compact
      suffix = tools.empty? ? "" : " tools: #{tools.join(', ')}"
      "#{plugin.fetch('name')}#{suffix}"
    end

    def render_session_command(payload)
      if payload["sessions"]
        return "No sessions" if payload.fetch("sessions").empty?

        payload.fetch("sessions").map do |session|
          labels = Array(session["labels"]).empty? ? "" : " [#{session.fetch('labels').join(', ')}]"
          "#{session.fetch('timestamp')} #{session.fetch('id')}#{labels} #{session.fetch('path')}"
        end.join("\n")
      elsif payload["deleted"]
        "Deleted #{payload.fetch('deleted').length} sessions"
      elsif payload["session"]
        session = payload.fetch("session")
        "Session #{session.fetch('id')} labels: #{Array(session['labels']).join(', ')}"
      else
        payload.inspect
      end
    end

    def approve_tool?(action:, target:, details:)
      if action == "plugin_tool"
        @stderr.puts "Plugin tool: #{details['plugin']} #{details['tool']}"
        @stderr.puts details["description"].to_s unless details["description"].to_s.empty?
        @stderr.puts "Arguments: #{JSON.generate(details['args'] || {})}"
      end
      @stderr.print "Approve #{action} #{target}? [y/N] "
      @stderr.flush if @stderr.respond_to?(:flush)
      answer = @stdin.gets.to_s.strip.downcase
      %w[y yes].include?(answer)
    end
  end
end
