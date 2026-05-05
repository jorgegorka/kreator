# frozen_string_literal: true

module Kreator
  class InteractiveCLI
    PROMPT_MARKER = "You"
    DEFAULT_MODELS = {
      "openai" => %w[gpt-5.2 gpt-5.2-pro gpt-5.2-codex gpt-5-mini gpt-5-nano gpt-4.1 gpt-4.1-mini],
      "anthropic" => %w[
        claude-sonnet-4-20250514
        claude-opus-4-1-20250805
        claude-opus-4-20250514
        claude-3-7-sonnet-20250219
        claude-3-5-haiku-20241022
      ],
      "openrouter" => %w[
        openrouter/auto
        openai/gpt-5.2
        anthropic/claude-sonnet-4
        google/gemini-2.5-pro
      ]
    }.freeze
    DEFAULT_CONTEXT_WINDOWS = {
      "openai" => [
        [/gpt-5(?:\.|-|\z)/, 400_000],
        [/4\.1|4o/, 128_000]
      ],
      "anthropic" => [
        [/.*/, 200_000]
      ],
      "openrouter" => [
        [/gpt-5(?:\.|-|\z)/, 400_000],
        [/4\.1|4o/, 128_000],
        [/claude/, 200_000]
      ]
    }.freeze
    COMMAND_AUTOCOMPLETE = [
      ["/exit", "exit the CLI"],
      ["/help", "show commands"],
      ["/new", "start a new session"],
      ["/resume", "resume recent session"],
      ["/model", "show or change model"],
      ["/session", "show or resume session"],
      ["/label", "label current session"],
      ["/search", "search sessions"],
      ["/export", "export current session"],
      ["/cleanup", "delete empty sessions"],
      ["/branches", "list session branches"],
      ["/fork", "fork session history"],
      ["/prompts", "list prompt templates"],
      ["/prompt", "run a prompt template"],
      ["/skills", "list skills"],
      ["/plugins", "list plugins"],
      ["/plugin validate", "validate a plugin"],
      ["/compact", "compact session context"]
    ].freeze
    Command = Struct.new(:pattern, :handler, keyword_init: true)
    MatchedCommand = Struct.new(:handler, :match, keyword_init: true)
    COMMANDS = [
      Command.new(pattern: %r{\A(?::q|/(?:exit|quit))\z}, handler: :exit_command),
      Command.new(pattern: %r{\A/help\z}, handler: :help_command),
      Command.new(pattern: %r{\A/new\z}, handler: :new_session_command),
      Command.new(pattern: %r{\A/resume\z}, handler: :resume_recent_command),
      Command.new(pattern: %r{\A/model\s+(.+)\z}, handler: :select_model_command),
      Command.new(pattern: %r{\A/model\z}, handler: :current_model_command),
      Command.new(pattern: %r{\A/session\s+(.+)\z}, handler: :resume_session_command),
      Command.new(pattern: %r{\A/session\z}, handler: :current_session_command),
      Command.new(pattern: %r{\A/label\s+(.+)\z}, handler: :label_session_command),
      Command.new(pattern: %r{\A/search\s+(.+)\z}, handler: :search_sessions_command),
      Command.new(pattern: %r{\A/export(?:\s+(\S+))?\z}, handler: :export_session_command),
      Command.new(pattern: %r{\A/cleanup\z}, handler: :cleanup_empty_sessions_command),
      Command.new(pattern: %r{\A/branches\z}, handler: :branches_command),
      Command.new(pattern: %r{\A/fork\s+(\d+)\z}, handler: :fork_session_command),
      Command.new(pattern: %r{\A/prompts\z}, handler: :prompts_command),
      Command.new(pattern: %r{\A/skills\z}, handler: :skills_command),
      Command.new(pattern: %r{\A/(?:plugins|plugin list)\z}, handler: :plugins_command),
      Command.new(pattern: %r{\A/plugin\s+validate\s+(.+)\z}, handler: :validate_plugin_command),
      Command.new(pattern: %r{\A/prompt\s+(\S+)(?:\s+(.+))?\z}m, handler: :prompt_template_command),
      Command.new(pattern: %r{\A/compact\z}, handler: :compact_command)
    ].freeze

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
      :stderr,
      :resources,
      :compact_threshold,
      keyword_init: true
    )

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
      @stderr = config.stderr
      @resources = config.resources || Resources.new
      @compact_threshold = config.compact_threshold
      @last_usage = nil
      @context_window = inferred_context_window
    end

    def run
      return run_line_mode unless tty?

      load_charm!
      Bubbletea.run(ChatModel.new(runtime: self))
      0
    rescue LoadError => e
      @stderr.puts "kreator: interactive mode requires Charm Ruby gems: #{e.message}"
      1
    end

    def submit(prompt)
      prompt = prompt.to_s.strip
      return [] if prompt.empty?

      command = matched_command(prompt)
      return send(command.handler, command.match) if command

      run_agent(prompt)
    rescue StandardError => e
      [system_line("#{e.class}: #{e.message}")]
    end

    def transcript
      messages.map { |message| format_message(message) }
    end

    def available_models
      (DEFAULT_MODELS.fetch(provider_name, []) | [model]).compact
    end

    def available_sessions
      session_manager.list(cwd: Dir.pwd)
    end

    def available_prompts
      resources.prompt_templates
    end

    def available_skills
      resources.skills
    end

    def available_plugins
      resources.plugins
    end

    def available_autocomplete_items
      command_items = COMMAND_AUTOCOMPLETE.map do |value, description|
        { value: value, label: value, description: description, kind: "command" }
      end
      skill_items = resources.skills.map do |skill|
        { value: "$#{skill.name}", label: "skill: #{skill.name}", description: "load skill context", kind: "skill" }
      end

      command_items + skill_items
    end

    def welcome_panel
      rows = [
        ">_ Kreator (v#{Kreator::VERSION})",
        "",
        "model:     #{model}   /model to change",
        "directory: #{display_directory}"
      ]
      content_width = [44, rows.map(&:length).max].max
      horizontal = "─" * (content_width + 2)

      [
        "╭#{horizontal}╮",
        *rows.map { |row| "│ #{row.ljust(content_width)} │" },
        "╰#{horizontal}╯"
      ].join("\n")
    end

    def select_model(model_name)
      @model = model_name
      @session&.append_model_change(provider: @provider_name, model: @model)
      @last_usage = nil
      @context_window = inferred_context_window
      system_line("Model set to #{@model}")
    end

    def resume_session(path)
      @session = @session_manager.open(path: path)
      system_line("Resumed session #{@session.id}")
    end

    def context_meter
      window = @context_window
      used = @last_usage&.fetch("total_tokens", nil)

      {
        window: window,
        used: used,
        available: window && used ? [window - used, 0].max : nil
      }
    end

    def fork_session(entry_index)
      return system_line("Session persistence disabled") unless session

      @session = session_manager.fork(path: session.path, entry_index: entry_index)
      system_line("Forked session #{@session.id} from entry #{entry_index}")
    end

    private

    attr_reader :provider_builder, :provider_name, :model, :tools, :context, :session_manager, :session, :resources

    def matched_command(prompt)
      COMMANDS.each do |command|
        match = command.pattern.match(prompt)
        return MatchedCommand.new(handler: command.handler, match: match) if match
      end

      nil
    end

    def exit_command(_match)
      throw :exit_interactive
    end

    def help_command(_match)
      [system_line(help_text)]
    end

    def new_session_command(_match)
      @session = @session_manager.create(cwd: Dir.pwd)
      [system_line("Started session #{@session.id}")]
    end

    def resume_recent_command(_match)
      @session = @session_manager.continue_recent(cwd: Dir.pwd)
      [system_line("Resumed session #{@session.id}")]
    end

    def select_model_command(match)
      [select_model(match[1].strip)]
    end

    def current_model_command(_match)
      [system_line("Current model: #{@model}. Press Ctrl+m for model picker.")]
    end

    def resume_session_command(match)
      [resume_session(match[1].strip)]
    end

    def current_session_command(_match)
      [system_line("#{session_summary}. Press Ctrl+r for session picker.")]
    end

    def label_session_command(match)
      [label_session(match[1].strip)]
    end

    def search_sessions_command(match)
      [system_line(search_sessions(match[1].strip))]
    end

    def export_session_command(match)
      [system_line(export_session(match[1] || "markdown"))]
    end

    def cleanup_empty_sessions_command(_match)
      [cleanup_empty_sessions]
    end

    def branches_command(_match)
      [system_line(branch_summary)]
    end

    def fork_session_command(match)
      [fork_session(Integer(match[1]))]
    end

    def prompts_command(_match)
      [system_line(resource_names("Prompt templates", resources.prompt_templates))]
    end

    def skills_command(_match)
      [system_line(resource_names("Skills", resources.skills))]
    end

    def plugins_command(_match)
      [system_line(plugin_summary)]
    end

    def validate_plugin_command(match)
      [system_line(validate_plugin(match[1].strip))]
    end

    def prompt_template_command(match)
      run_agent(match[2].to_s, template: match[1])
    end

    def compact_command(_match)
      [compact_session]
    end

    def run_line_mode
      @stdout.puts welcome_panel
      @stdout.puts "Type /help for commands, /exit to quit."
      catch(:exit_interactive) do
        loop do
          @stdout.print "> "
          @stdout.flush if @stdout.respond_to?(:flush)
          line = @stdin.gets
          break unless line

          submit(line).each { |entry| @stdout.puts entry }
        end
      end
      0
    end

    def run_agent(prompt, template: nil)
      prompt = materialize_prompt(prompt, template)
      provider = provider_builder.call(provider_name)
      update_context_window(provider)
      event_bus = EventBus.new
      entries = [format_message(Message.user(prompt))]
      assistant_buffer = +""
      event_bus.subscribe("message_delta") { |event| assistant_buffer << event.fetch(:delta, "").to_s }
      event_bus.subscribe("tool_start") do |event|
        next unless event[:execution]

        tool_call = event.fetch(:tool_call)
        entries << TranscriptEntry.new(role: "tool", title: "tool: #{tool_call.fetch('name')} started")
      end
      event_bus.subscribe("tool_end") do |event|
        next unless event[:execution]

        result = event.fetch(:result)
        entries << TranscriptEntry.new(
          role: "tool",
          title: "tool: #{result.fetch('name')} #{result.fetch('status')}",
          body: result.fetch("content", ""),
          collapsible: true
        )
      end

      maybe_compact_session
      current_messages = messages
      previous_message_count = current_messages.length
      agent = AgentLoop.new(
        provider: provider,
        event_bus: event_bus,
        system_prompt: resources.system_prompt(base_prompt: AgentLoop::DEFAULT_SYSTEM_PROMPT, prompt: prompt),
        model: model,
        tools: tools,
        context: context
      )
      final_message = agent.run(prompt: prompt, messages: current_messages)
      new_messages = agent.last_messages.drop(previous_message_count)
      persist_messages(new_messages)
      session&.append_session_info("usage" => agent.last_usage) if agent.last_usage
      @last_usage = agent.last_usage if agent.last_usage
      entries << format_message(final_message) unless assistant_buffer.empty?
      entries
    end

    def messages
      return [] unless session

      session.compaction_entries.empty? ? session.messages : session.compacted_messages
    end

    def persist_messages(new_messages)
      return unless session

      new_messages.each { |message| session.append_message(message) }
    end

    def format_message(message)
      case message.role
      when "user"
        TranscriptEntry.new(role: "user", title: "#{PROMPT_MARKER}: #{message.content}")
      when "assistant"
        rendered = render_markdown(message.content)
        TranscriptEntry.new(role: "assistant", title: "Kreator: #{rendered}")
      when "tool"
        TranscriptEntry.new(
          role: "tool",
          title: "tool: #{message.name || message.tool_call_id}",
          body: message.content,
          collapsible: true
        )
      else
        TranscriptEntry.new(role: message.role, title: "#{message.role}: #{message.content}")
      end
    end

    def render_markdown(content)
      return content unless defined?(Glamour)

      Glamour.render(content, style: "dark", width: 88).strip
    rescue StandardError
      content
    end

    def system_line(content)
      "system: #{content}"
    end

    def session_summary
      return "Session persistence disabled" unless session

      "Session #{session.id} at #{session.path}"
    end

    def help_text
      "Commands: /new, /resume, /model [name], /session [id|path], /label NAME, /search QUERY, /export [markdown|plain|json], /cleanup, /branches, /fork INDEX, /prompts, /prompt NAME text, /skills, /plugins, /plugin list, /plugin validate NAME, /compact, /help, /exit. TUI: Ctrl+m model picker, Ctrl+r session picker, Ctrl+t toggles tool output."
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

    def compact_session
      return system_line("Session persistence disabled") unless session

      compacted = session.compact!
      system_line("Compacted session to #{compacted.length} context messages")
    end

    def label_session(label)
      return system_line("Session persistence disabled") unless session

      @session = session_manager.label(path: session.path, label: label)
      system_line("Session labels: #{session.labels.join(', ')}")
    end

    def search_sessions(query)
      matches = session_manager.search(query: query, cwd: Dir.pwd)
      return "Sessions: none" if matches.empty?

      "Sessions: #{matches.map { |summary| session_list_label(summary) }.join('; ')}"
    end

    def export_session(format)
      return "Session persistence disabled" unless session

      session_manager.export(path: session.path, format: format)
    end

    def cleanup_empty_sessions
      deleted = session_manager.cleanup(cwd: Dir.pwd, empty: true)
      system_line("Deleted #{deleted.length} empty sessions")
    end

    def resource_names(label, files)
      return "#{label}: none" if files.empty?

      "#{label}: #{files.map(&:name).join(', ')}"
    end

    def branch_summary
      return "Session persistence disabled" unless session

      branches = session_manager.branches(parent_id: session.id)
      return "Branches: none" if branches.empty?

      "Branches: #{branches.map { |summary| summary.fetch('id') }.join(', ')}"
    end

    def session_list_label(summary)
      labels = Array(summary["labels"]).empty? ? "" : " [#{summary.fetch('labels').join(', ')}]"
      "#{summary.fetch('id')}#{labels}"
    end

    def plugin_summary
      plugins = resources.plugins
      return "Plugins: none" if plugins.empty?

      tools_by_plugin = resources.plugin_tools.group_by { |tool| tool.plugin.name }
      "Plugins: #{plugins.map { |plugin| plugin_summary_entry(plugin, tools_by_plugin.fetch(plugin.name, [])) }.join('; ')}"
    end

    def plugin_summary_entry(plugin, tools)
      return plugin.name if tools.empty?

      "#{plugin.name} tools: #{tools.map(&:name).join(', ')}"
    end

    def validate_plugin(name)
      validation = resources.plugin_manager.validate(name)
      return "Plugin #{validation.fetch('plugin').fetch('name')} ok" if validation.fetch("ok")

      "Plugin #{validation.fetch('plugin').fetch('name')} errors: #{validation.fetch('errors').join('; ')}"
    end

    def update_context_window(provider)
      return unless provider.respond_to?(:capabilities)

      @context_window = provider.capabilities(model)["context_window"] || @context_window
    rescue StandardError
      @context_window ||= inferred_context_window
    end

    def inferred_context_window
      DEFAULT_CONTEXT_WINDOWS.fetch(provider_name, []).each do |pattern, window|
        return window if model.to_s.match?(pattern)
      end

      nil
    end

    def display_directory
      home = Dir.home
      cwd = Dir.pwd
      return "~" if cwd == home
      return cwd.sub(%r{\A#{Regexp.escape(home)}(?=/)}, "~") if cwd.start_with?("#{home}/")

      cwd
    rescue ArgumentError
      Dir.pwd
    end

    def tty?
      @stdin.respond_to?(:tty?) && @stdin.tty? && @stdout.respond_to?(:tty?) && @stdout.tty?
    end

    def load_charm!
      require "bubbletea"
      require "bubbles"
      require "lipgloss"
      require "glamour"
      ChatModel.include(Bubbletea::Model) unless ChatModel < Bubbletea::Model
    end

    class TranscriptEntry
      attr_reader :role, :title, :body
      attr_accessor :expanded

      def initialize(role:, title:, body: nil, collapsible: false, expanded: false)
        @role = role
        @title = title
        @body = body.to_s
        @collapsible = collapsible
        @expanded = expanded
      end

      def collapsible?
        @collapsible
      end

      def toggle
        return unless collapsible?

        @expanded = !expanded
      end

      def to_s
        return title unless collapsible?

        marker = expanded ? "[-]" : "[+]"
        return "#{marker} #{title}" unless expanded && !body.empty?

        "#{marker} #{title}\n#{body}"
      end
    end

    class ChatModel
      def initialize(runtime:)
        @runtime = runtime
        @lines = [runtime.welcome_panel, *runtime.transcript]
        @mode = :chat
        @model_list = nil
        @session_list = nil
        @draft_buffer = nil
        @autocomplete_index = 0
        @autocomplete_completed = false
        @textarea = Bubbles::TextArea.new(width: 80, height: 3)
        @textarea.placeholder = "Send a message..."
        @textarea.prompt = "> "
        @textarea.show_line_numbers = false
        @textarea.focus
        @viewport = Bubbles::Viewport.new(width: 88, height: 24)
        refresh_viewport
        @title_style = defined?(Lipgloss) ? Lipgloss::Style.new.bold(true).foreground("#2D7D9A") : nil
        @status_style = defined?(Lipgloss) ? Lipgloss::Style.new.foreground("#6B7280") : nil
      end

      CHAT_KEY_HANDLERS = {
        "ctrl+c" => :quit_update,
        "esc" => :quit_update,
        "ctrl+m" => :open_model_picker_update,
        "ctrl+r" => :open_session_picker_update,
        "ctrl+t" => :toggle_next_tool_update,
        "ctrl+s" => :save_draft_update,
        "enter" => :submit_prompt_update,
        "alt+enter" => :insert_newline_update
      }.freeze

      def init = [self, @textarea.cursor.focus]

      def update(message)
        return update_window(message) if message.is_a?(Bubbletea::WindowSizeMessage)
        return update_key(message) if message.is_a?(Bubbletea::KeyMessage)

        update_inputs(message)
      end

      def view
        title = styled(@title_style, "Kreator")
        status = styled(@status_style, status_text)
        return [title, status, "", picker_view].join("\n") unless @mode == :chat

        [title, status, "", @viewport.view, "", @textarea.view, autocomplete_panel, context_bar].compact.join("\n")
      end

      private

      def update_window(message)
        @viewport.width = [message.width, 40].max
        @viewport.height = [message.height - 13, 8].max
        @textarea.width = [message.width - 4, 30].max
        refresh_viewport
        update_inputs(message)
      end

      def update_key(message)
        key = message.to_s
        return update_picker(message, key) unless @mode == :chat
        return update_autocomplete(key) if autocomplete_handles?(key)

        handler = CHAT_KEY_HANDLERS[key]
        handler ? send(handler) : update_inputs(message)
      end

      def update_inputs(message)
        @viewport, viewport_command = @viewport.update(message)
        @textarea, textarea_command = update_textarea(message)
        [self, Bubbletea.batch(*[viewport_command, textarea_command].compact)]
      end

      def update_textarea(message)
        previous_value = @textarea.value
        textarea, command = @textarea.update(message)
        if textarea.value != previous_value
          @autocomplete_index = 0
          @autocomplete_completed = false
        end

        [textarea, command]
      end

      def quit_update
        [self, Bubbletea.quit]
      end

      def open_model_picker_update
        open_model_picker
        [self, nil]
      end

      def open_session_picker_update
        open_session_picker
        [self, nil]
      end

      def toggle_next_tool_update
        toggle_next_tool
        refresh_viewport
        [self, nil]
      end

      def save_draft_update
        @draft_buffer = @textarea.value
        @textarea.reset
        [self, nil]
      end

      def insert_newline_update
        update_inputs(Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ENTER, name: "enter"))
      end

      def submit_prompt_update
        prompt = @textarea.value
        return [self, Bubbletea.quit] if prompt.strip.match?(%r{\A(?::q|/exit)\z})

        catch(:exit_interactive) do
          @lines.concat(@runtime.submit(prompt))
          @textarea.reset
          restore_draft
          refresh_viewport
          return [self, nil]
        end
        [self, Bubbletea.quit]
      end

      def restore_draft
        return if @draft_buffer.nil?

        @textarea.value = @draft_buffer
        @draft_buffer = nil
      end

      def refresh_viewport
        @viewport.content = wrapped_viewport_content
        @viewport.x_offset = 0
        @viewport.goto_bottom
      end

      def wrapped_viewport_content
        width = [@viewport.width, 1].max

        @lines.map { |line| wrap_block(line.to_s, width) }.join("\n\n")
      end

      def wrap_block(block, width)
        block.split("\n", -1).flat_map { |line| wrap_line(line, width) }.join("\n")
      end

      def wrap_line(line, width)
        total_width = visible_width(line)
        return [line] if total_width <= width

        wrapped = []
        start_column = 0

        while start_column < total_width
          start_column = skip_visible_spaces(line, start_column, total_width)
          break if start_column >= total_width

          remaining_width = total_width - start_column
          if remaining_width <= width
            wrapped << Bubbles::ANSI.cut_string(line, start_column, total_width)
            break
          end

          break_column = word_break_column(line, start_column, width)
          wrapped << Bubbles::ANSI.cut_string(line, start_column, start_column + break_column)
          start_column += break_column
        end

        wrapped.empty? ? [""] : wrapped
      end

      def word_break_column(line, start_column, width)
        plain = Bubbles::ANSI.strip(Bubbles::ANSI.cut_string(line, start_column, start_column + width + 1))
        break_column = nil

        plain.each_char.with_index do |char, index|
          break if index > width

          break_column = index if char.match?(/[ \t]/)
        end

        return break_column if break_column&.positive?

        width
      end

      def skip_visible_spaces(line, start_column, total_width)
        start_column += 1 while start_column < total_width && visible_char(line, start_column).match?(/[ \t]/)
        start_column
      end

      def visible_char(line, column)
        Bubbles::ANSI.strip(Bubbles::ANSI.cut_string(line, column, column + 1))
      end

      def visible_width(line)
        Bubbles::ANSI.strip(line).length
      end

      def status_text
        case @mode
        when :model_picker
          "Model picker: Enter selects, Esc cancels, / filters"
        when :session_picker
          "Session picker: Enter resumes, Esc cancels, / filters"
        else
          "Enter sends, Alt+Enter inserts newline, Ctrl+s saves draft, Ctrl+m model picker, Ctrl+r session picker, Ctrl+t toggles tool output"
        end
      end

      def context_bar
        meter = @runtime.context_meter
        width = [@textarea.width - 38, 10].max
        window = meter.fetch(:window)
        used = meter.fetch(:used)

        return "context: #{empty_bar(width)} unknown window" unless window
        return "context: #{empty_bar(width)} #{format_tokens(window)} window" unless used

        available = meter.fetch(:available)
        available_ratio = window.positive? ? available.to_f / window : 0.0
        filled = (available_ratio * width).round.clamp(0, width)
        bar = "[#{'█' * filled}#{'░' * (width - filled)}]"
        percent = (available_ratio * 100).round
        "context: #{bar} #{percent}% available (#{format_tokens(available)}/#{format_tokens(window)})"
      end

      def empty_bar(width)
        "[#{'░' * width}]"
      end

      def format_tokens(tokens)
        return "?" unless tokens
        return tokens.to_s if tokens < 1_000

        formatted = tokens >= 100_000 ? (tokens / 1_000.0).round.to_s : format("%.1f", tokens / 1_000.0).sub(/\.0\z/, "")
        "#{formatted}k"
      end

      def autocomplete_panel
        return unless autocomplete_active?

        suggestions = autocomplete_suggestions.first(5)
        return "  no matches" if suggestions.empty?

        clamp_autocomplete_index(suggestions)
        suggestions.each_with_index.map { |item, index| autocomplete_line(item, selected: index == @autocomplete_index) }.join("\n")
      end

      def autocomplete_active?
        @textarea.value.start_with?("/") && !autocomplete_completed?
      end

      def autocomplete_completed?
        @autocomplete_completed || @textarea.value.match?(/\s/)
      end

      def autocomplete_handles?(key)
        autocomplete_active? && autocomplete_suggestions.any? && %w[up down enter tab].include?(key)
      end

      def update_autocomplete(key)
        suggestions = autocomplete_suggestions.first(5)
        clamp_autocomplete_index(suggestions)

        case key
        when "up"
          @autocomplete_index = (@autocomplete_index - 1) % suggestions.length
        when "down"
          @autocomplete_index = (@autocomplete_index + 1) % suggestions.length
        when "enter", "tab"
          complete_autocomplete(suggestions.fetch(@autocomplete_index))
        end

        [self, nil]
      end

      def complete_autocomplete(item)
        @textarea.value = autocomplete_completion(item)
        @autocomplete_index = 0
        @autocomplete_completed = true
      end

      def autocomplete_completion(item)
        value = item.fetch(:value)
        return "#{value} " if autocomplete_continues?(item)

        value
      end

      def autocomplete_continues?(item)
        item.fetch(:kind) == "skill" || [
          "/model",
          "/session",
          "/label",
          "/search",
          "/fork",
          "/prompt",
          "/plugin validate"
        ].include?(item.fetch(:value))
      end

      def clamp_autocomplete_index(suggestions)
        @autocomplete_index = 0 if @autocomplete_index >= suggestions.length
      end

      def autocomplete_suggestions
        query = @textarea.value.delete_prefix("/").downcase
        @runtime.available_autocomplete_items.select do |item|
          autocomplete_text(item).include?(query)
        end
      end

      def autocomplete_text(item)
        [item.fetch(:label), item.fetch(:value), item.fetch(:description), item.fetch(:kind)].join(" ").downcase
      end

      def autocomplete_line(item, selected:)
        label = item.fetch(:label)
        description = item.fetch(:description)
        marker = selected ? ">" : " "
        "#{marker} #{label.ljust(18)} #{description}"
      end

      def open_model_picker
        @mode = :model_picker
        @model_list = Bubbles::List.new(@runtime.available_models.map { |model| picker_item(model, model) }, width: @viewport.width, height: @viewport.height)
        @model_list.title = "Select model"
      end

      def open_session_picker
        @mode = :session_picker
        items = @runtime.available_sessions.map do |session|
          label = "#{session.fetch('timestamp')} #{session.fetch('id')}"
          picker_item(label, session.fetch("path"))
        end
        @session_list = Bubbles::List.new(items, width: @viewport.width, height: @viewport.height)
        @session_list.title = "Select session"
      end

      def update_picker(message, key)
        case key
        when "esc"
          @mode = :chat
          return [self, nil]
        when "enter"
          select_picker_item
          @mode = :chat
          refresh_viewport
          return [self, nil]
        end

        list = current_picker
        updated, command = list.update(message)
        @model_list = updated if @mode == :model_picker
        @session_list = updated if @mode == :session_picker
        [self, command]
      end

      def select_picker_item
        item = current_picker&.selected_item
        return unless item

        if @mode == :model_picker
          @lines << @runtime.select_model(item.fetch(:value))
        else
          @lines << @runtime.resume_session(item.fetch(:value))
          @lines = @runtime.transcript + @lines.last(1)
        end
      rescue StandardError => e
        @lines << "system: #{e.class}: #{e.message}"
      end

      def picker_view
        current_picker.view
      end

      def current_picker
        @mode == :model_picker ? @model_list : @session_list
      end

      def picker_item(title, value)
        { title: title, value: value }
      end

      def toggle_next_tool
        collapsible = @lines.select { |entry| entry.respond_to?(:collapsible?) && entry.collapsible? }
        return if collapsible.empty?

        @tool_toggle_index ||= -1
        @tool_toggle_index = (@tool_toggle_index + 1) % collapsible.length
        collapsible[@tool_toggle_index].toggle
      end

      def styled(style, text)
        style ? style.render(text) : text
      end
    end
  end
end
