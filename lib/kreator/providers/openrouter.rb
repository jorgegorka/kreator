# frozen_string_literal: true

module Kreator
  module Providers
    class OpenRouter < OpenAI
      DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"

      def initialize(
        api_key: ENV.fetch("OPENROUTER_API_KEY", nil),
        base_url: ENV.fetch("OPENROUTER_BASE_URL", DEFAULT_BASE_URL),
        site_url: ENV.fetch("OPENROUTER_SITE_URL", nil),
        app_name: ENV.fetch("OPENROUTER_APP_NAME", nil),
        max_retries: DEFAULT_MAX_RETRIES
      )
        raise Error, "OPENROUTER_API_KEY is required for the openrouter provider" if api_key.to_s.empty?

        @site_url = site_url
        @app_name = app_name
        super(api_key: api_key, base_url: base_url, name: "openrouter", max_retries: max_retries)
      end

      private

      def openai_headers
        super.tap do |headers|
          headers["HTTP-Referer"] = @site_url unless @site_url.to_s.empty?
          headers["X-OpenRouter-Title"] = @app_name unless @app_name.to_s.empty?
        end
      end
    end
  end
end
