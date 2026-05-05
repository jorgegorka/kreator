# frozen_string_literal: true

require "optparse"

module Kreator
  class CLI
    DEFAULT_PROVIDER = "openai"
    DEFAULT_MODEL = "gpt-4o-mini"

    def initialize(argv, stdout:, stderr:, provider_builder: Providers.method(:build))
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @provider_builder = provider_builder
      @options = {
        provider: ENV.fetch("KREATOR_PROVIDER", DEFAULT_PROVIDER),
        model: ENV.fetch("KREATOR_MODEL", DEFAULT_MODEL)
      }
    end

    def run
      parser.parse!(@argv)
      prompt = @argv.join(" ").strip

      if prompt.empty?
        @stderr.puts parser
        return 1
      end

      provider = @provider_builder.call(@options.fetch(:provider))
      event_bus = EventBus.new
      event_bus.subscribe("message_delta") { |event| @stdout.print event.fetch(:delta) }
      agent = AgentLoop.new(provider: provider, event_bus: event_bus, model: @options.fetch(:model))
      agent.run(prompt: prompt)
      @stdout.puts
      0
    rescue OptionParser::ParseError, ArgumentError, Providers::Error => error
      @stderr.puts "kreator: #{error.message}"
      1
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: kreator [options] \"prompt\""

        opts.on("--provider PROVIDER", "Provider to use: openai or anthropic") do |provider|
          @options[:provider] = provider
        end

        opts.on("--model MODEL", "Provider model name") do |model|
          @options[:model] = model
        end

        opts.on("-h", "--help", "Print help") do
          @stdout.puts opts
          exit 0
        end
      end
    end
  end
end
