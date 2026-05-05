# frozen_string_literal: true

require_relative "providers/base"
require_relative "providers/openai_auth"
require_relative "providers/openai"
require_relative "providers/anthropic"
require_relative "providers/openrouter"

module Kreator
  module Providers
    PROVIDERS = {
      "openai" => OpenAI,
      "anthropic" => Anthropic,
      "openrouter" => OpenRouter
    }.freeze

    def self.build(name, **)
      provider = PROVIDERS[name.to_s]
      raise ArgumentError, "unknown provider: #{name}" unless provider

      provider.new(**)
    end
  end
end
