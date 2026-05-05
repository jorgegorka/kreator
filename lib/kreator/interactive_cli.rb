# frozen_string_literal: true

module Kreator
  class InteractiveCLI
    PROMPT_MARKER = "You"
    DEFAULT_MODELS = {
      "openai" => %w[gpt-4o-mini gpt-4o gpt-4.1-mini gpt-4.1],
      "anthropic" => %w[claude-3-5-haiku-latest claude-3-5-sonnet-latest claude-3-7-sonnet-latest]
    }.freeze

    def initialize(provider_builder:, provider_name:, model:, tools:, context:, session_manager:, session:, stdin:, stdout:, stderr:)
      @provider_builder = provider_builder
      @provider_name = provider_name
      @model = model
      @tools = tools
      @context = context
      @session_manager = session_manager
      @session = session
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
    end

    def run
      return run_line_mode unless tty?

      load_charm!
      Bubbletea.run(ChatModel.new(runtime: self))
      0
    rescue LoadError => error
      @stderr.puts "kreator: interactive mode requires Charm Ruby gems: #{error.message}"
      1
    end

    def submit(prompt)
      prompt = prompt.to_s.strip
      return [] if prompt.empty?

      case prompt
      when "/exit", "/quit"
        throw :exit_interactive
      when "/help"
        return [system_line(help_text)]
      when "/new"
        @session = @session_manager.create(cwd: Dir.pwd)
        return [system_line("Started session #{@session.id}")]
      when "/resume"
        @session = @session_manager.continue_recent(cwd: Dir.pwd)
        return [system_line("Resumed session #{@session.id}")]
      when %r{\A/model\s+(.+)\z}
        return [select_model(Regexp.last_match(1).strip)]
      when "/model"
        return [system_line("Current model: #{@model}. Press Ctrl+m for model picker.")]
      when "/session"
        return [system_line("#{session_summary}. Press Ctrl+r for session picker.")]
      end

      run_agent(prompt)
    rescue StandardError => error
      [system_line("#{error.class}: #{error.message}")]
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

    def select_model(model_name)
      @model = model_name
      @session&.append_model_change(provider: @provider_name, model: @model)
      system_line("Model set to #{@model}")
    end

    def resume_session(path)
      @session = @session_manager.open(path: path)
      system_line("Resumed session #{@session.id}")
    end

    private

    attr_reader :provider_builder, :provider_name, :model, :tools, :context, :session_manager, :session

    def run_line_mode
      @stdout.puts "Kreator interactive mode. Type /help for commands, /exit to quit."
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

    def run_agent(prompt)
      provider = provider_builder.call(provider_name)
      event_bus = EventBus.new
      entries = [format_message(Message.user(prompt))]
      assistant_buffer = +""
      event_bus.subscribe("message_delta") { |event| assistant_buffer << event.fetch(:delta, "").to_s }
      event_bus.subscribe("tool_start") do |event|
        next unless event[:execution]

        tool_call = event.fetch(:tool_call)
        entries << TranscriptEntry.new(role: "tool", title: "tool: #{tool_call.fetch("name")} started")
      end
      event_bus.subscribe("tool_end") do |event|
        next unless event[:execution]

        result = event.fetch(:result)
        entries << TranscriptEntry.new(
          role: "tool",
          title: "tool: #{result.fetch("name")} #{result.fetch("status")}",
          body: result.fetch("content", ""),
          collapsible: true
        )
      end

      current_messages = messages
      previous_message_count = current_messages.length
      agent = AgentLoop.new(provider: provider, event_bus: event_bus, model: model, tools: tools, context: context)
      final_message = agent.run(prompt: prompt, messages: current_messages)
      new_messages = agent.last_messages.drop(previous_message_count)
      persist_messages(new_messages)
      entries << format_message(final_message) unless assistant_buffer.empty?
      entries
    end

    def messages
      session ? session.messages : []
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
      "Commands: /new, /resume, /model [name], /session, /help, /exit. TUI: Ctrl+m model picker, Ctrl+r session picker, Ctrl+t toggles tool output."
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
        @lines = runtime.transcript
        @mode = :chat
        @model_list = nil
        @session_list = nil
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

      def init = [self, @textarea.cursor.focus]

      def update(message)
        case message
        when Bubbletea::WindowSizeMessage
          @viewport.width = [message.width, 40].max
          @viewport.height = [message.height - 7, 8].max
          @textarea.width = [message.width - 4, 30].max
        when Bubbletea::KeyMessage
          key = message.to_s
          return update_picker(message, key) unless @mode == :chat

          case key
          when "ctrl+c", "esc"
            return [self, Bubbletea.quit]
          when "ctrl+m"
            open_model_picker
            return [self, nil]
          when "ctrl+r"
            open_session_picker
            return [self, nil]
          when "ctrl+t"
            toggle_next_tool
            refresh_viewport
            return [self, nil]
          when "ctrl+s"
            prompt = @textarea.value
            return [self, Bubbletea.quit] if prompt.strip == "/exit"

            catch(:exit_interactive) do
              @lines.concat(@runtime.submit(prompt))
              @textarea.reset
              refresh_viewport
              return [self, nil]
            end
            return [self, Bubbletea.quit]
          end
        end

        @viewport, viewport_command = @viewport.update(message)
        @textarea, textarea_command = @textarea.update(message)
        [self, Bubbletea.batch(*[viewport_command, textarea_command].compact)]
      end

      def view
        title = styled(@title_style, "Kreator")
        status = styled(@status_style, status_text)
        return [title, status, "", picker_view].join("\n") unless @mode == :chat

        [title, status, "", @viewport.view, "", @textarea.view].join("\n")
      end

      private

      def refresh_viewport
        @viewport.content = @lines.map(&:to_s).join("\n\n")
        @viewport.goto_bottom
      end

      def status_text
        case @mode
        when :model_picker
          "Model picker: Enter selects, Esc cancels, / filters"
        when :session_picker
          "Session picker: Enter resumes, Esc cancels, / filters"
        else
          "Ctrl+s sends, Enter inserts newline, Ctrl+m model picker, Ctrl+r session picker, Ctrl+t toggles tool output"
        end
      end

      def open_model_picker
        @mode = :model_picker
        @model_list = Bubbles::List.new(@runtime.available_models.map { |model| picker_item(model, model) }, width: @viewport.width, height: @viewport.height)
        @model_list.title = "Select model"
      end

      def open_session_picker
        @mode = :session_picker
        items = @runtime.available_sessions.map do |session|
          label = "#{session.fetch("timestamp")} #{session.fetch("id")}"
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
      rescue StandardError => error
        @lines << "system: #{error.class}: #{error.message}"
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
