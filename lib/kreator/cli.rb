# frozen_string_literal: true

require "json"
require "optparse"

module Kreator
  class CLI
    DEFAULT_PROVIDER = "openai"
    DEFAULT_MODEL = "gpt-4o-mini"

    def initialize(argv, stdin: $stdin, stdout:, stderr:, provider_builder: Providers.method(:build))
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
        json: false,
        rpc: false
      }
    end

    def run
      parser.parse!(@argv)
      return run_rpc if @options.fetch(:rpc)

      prompt = @argv.join(" ").strip

      if prompt.empty?
        @stderr.puts parser
        return 1
      end

      result = run_prompt(prompt)
      if @options.fetch(:json)
        @stdout.puts JSON.generate(result)
      else
        @stdout.puts
      end
      0
    rescue OptionParser::ParseError, ArgumentError, Providers::Error, ToolRegistry::Error, AgentLoop::Error => error
      if @options[:json]
        @stdout.puts JSON.generate("ok" => false, "error" => error_hash(error))
      else
        @stderr.puts "kreator: #{error.message}"
      end
      1
    end

    private

    def run_prompt(prompt)
      provider = @provider_builder.call(@options.fetch(:provider))
      event_bus = EventBus.new
      event_bus.subscribe("message_delta") { |event| @stdout.print event.fetch(:delta) } unless @options.fetch(:json)
      tools = build_tools
      context = ToolContext.new(bash_timeout: @options.fetch(:timeout))
      session = build_session
      messages = session&.messages || []
      previous_message_count = messages.length
      agent = AgentLoop.new(
        provider: provider,
        event_bus: event_bus,
        model: @options.fetch(:model),
        tools: tools,
        context: context
      )
      final_message = agent.run(prompt: prompt, messages: messages)
      new_messages = agent.last_messages.drop(previous_message_count)
      persist_messages(session, new_messages) if session
      {
        "ok" => true,
        "message" => final_message.to_h,
        "messages" => new_messages.map(&:to_h),
        "tool_calls" => final_message.tool_calls.map(&:to_h),
        "usage" => nil,
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
          raise OptionParser::InvalidArgument, "--timeout must be positive" unless seconds.positive?

          @options[:timeout] = seconds
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

    def build_tools
      return ToolRegistry.new if @options.fetch(:no_tools)

      registry = ToolRegistry.default(bash_timeout: @options.fetch(:timeout))
      @options[:tools] ? registry.select_names(@options.fetch(:tools)) : registry
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

      tools = build_tools
      context = ToolContext.new(bash_timeout: @options.fetch(:timeout))
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
        stdin: @stdin,
        stdout: @stdout
      ).run
    end

    def session_payload(session)
      return nil unless session

      {
        "id" => session.id,
        "path" => session.path,
        "cwd" => session.cwd
      }
    end

    def error_hash(error)
      { "class" => error.class.name, "message" => error.message }
    end
  end
end
