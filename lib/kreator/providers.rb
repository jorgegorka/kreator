# frozen_string_literal: true

require_relative "providers/base"
require_relative "providers/openai"
require_relative "providers/anthropic"

module Kreator
  module Providers
    PROVIDERS = {
      "openai" => OpenAI,
      "anthropic" => Anthropic
    }.freeze

    def self.build(name, **)
      provider = PROVIDERS[name.to_s]
      raise ArgumentError, "unknown provider: #{name}" unless provider

      provider.new(**)
    end
  end
end
