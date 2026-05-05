# frozen_string_literal: true

require "json"
require "net/http"
require "timeout"
require "uri"

module Kreator
  module Providers
    class Error < StandardError
      attr_reader :code, :status, :retryable, :details

      def initialize(message, code: "provider_error", status: nil, retryable: false, details: {})
        super(message)
        @code = code.to_s
        @status = status
        @retryable = retryable
        @details = details || {}
      end

      def to_h
        {
          "code" => code,
          "class" => self.class.name,
          "message" => message,
          "status" => status,
          "retryable" => retryable,
          "details" => details
        }.compact
      end
    end

    class Base
      DEFAULT_MAX_RETRIES = 2
      TRANSIENT_HTTP_STATUSES = [408, 409, 429, 500, 502, 503, 504].freeze

      attr_reader :api_key, :base_url, :name, :max_retries

      def initialize(api_key:, base_url:, name:, max_retries: DEFAULT_MAX_RETRIES)
        @api_key = api_key
        @base_url = base_url
        @name = name
        @max_retries = Integer(max_retries)
      end

      def stream(messages:, tools:, system_prompt:, model:, signal:)
        raise NotImplementedError, "#{self.class} must implement #stream"
      end

      def capabilities(model)
        {
          "model" => model,
          "provider" => name,
          "streaming" => true,
          "tools" => true,
          "vision" => false,
          "reasoning" => false,
          "context_window" => nil
        }
      end

      private

      def post_json_stream(path, body, headers: {}, &block)
        with_retries do
          request_json(path, body, headers: headers) do |response|
            response.read_body(&block)
          end
        end
      end

      def post_json(path, body, headers: {})
        response_body = +""
        with_retries do
          request_json(path, body, headers: headers) do |response|
            response.read_body { |chunk| response_body << chunk }
          end
        end
        JSON.parse(response_body)
      rescue JSON::ParserError => e
        raise Error.new("invalid #{name} JSON response: #{e.message}", code: "invalid_response", retryable: false)
      end

      def request_json(path, body, headers: {})
        uri = URI.join(base_url.end_with?("/") ? base_url : "#{base_url}/", path)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        headers.each { |key, value| request[key] = value }
        request.body = JSON.generate(body)

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request) do |response|
            unless response.is_a?(Net::HTTPSuccess)
              response_body = +""
              response.read_body { |chunk| response_body << chunk }
              raise provider_http_error(response, response_body)
            end

            yield response
          end
        end
      rescue Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError => e
        raise Error.new(
          "#{name} request failed: #{e.message}",
          code: "network_error",
          retryable: true,
          details: { "class" => e.class.name }
        )
      end

      def parse_sse_stream(producer, &block)
        buffer = +""

        producer.call(lambda do |chunk|
          buffer << chunk
          drain_sse_buffer(buffer) { |data| block.call(data) }
        end)

        flush_sse_buffer(buffer) { |data| block.call(data) }
      end

      def with_retries
        attempts = 0

        begin
          attempts += 1
          yield
        rescue Error => e
          raise unless e.retryable && attempts <= max_retries

          sleep retry_delay(attempts)
          retry
        end
      end

      def retry_delay(attempt)
        [0.1 * (2**(attempt - 1)), 1.0].min
      end

      def provider_http_error(response, body)
        status = response.code.to_i
        message, code = parse_http_error_body(body)

        Error.new(
          "#{name} request failed: HTTP #{status} #{message}",
          code: code,
          status: status,
          retryable: TRANSIENT_HTTP_STATUSES.include?(status),
          details: { "body" => body }
        )
      end

      def parse_http_error_body(body)
        parsed = JSON.parse(body)
        [
          parsed.dig("error", "message") || body,
          parsed.dig("error", "code") || parsed.dig("error", "type") || "http_error"
        ]
      rescue JSON::ParserError
        [body, "http_error"]
      end

      def drain_sse_buffer(buffer)
        while (index = buffer.index("\n\n"))
          data = sse_data(buffer.slice!(0, index + 2))
          yield data unless data.empty?
        end
      end

      def flush_sse_buffer(buffer)
        return if buffer.strip.empty?

        data = sse_data(buffer)
        yield data unless data.empty?
      end

      def sse_data(raw_event)
        raw_event.each_line.filter_map do |line|
          line = line.chomp
          line.start_with?("data:") ? line.delete_prefix("data:").strip : nil
        end.join("\n")
      end
    end
  end
end
