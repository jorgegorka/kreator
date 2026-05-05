# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Kreator
  module Providers
    class Error < StandardError; end

    class Base
      attr_reader :api_key, :base_url, :name

      def initialize(api_key:, base_url:, name:)
        @api_key = api_key
        @base_url = base_url
        @name = name
      end

      def stream(messages:, tools:, system_prompt:, model:, signal:)
        raise NotImplementedError, "#{self.class} must implement #stream"
      end

      private

      def post_json_stream(path, body, headers: {})
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
              raise Error, "#{name} request failed: HTTP #{response.code} #{response_body}"
            end

            response.read_body do |chunk|
              yield chunk
            end
          end
        end
      end

      def parse_sse_stream(producer)
        buffer = +""

        yield_chunk = lambda do |chunk|
          buffer << chunk
          while (index = buffer.index("\n\n"))
            raw_event = buffer.slice!(0, index + 2)
            data_lines = raw_event.each_line.filter_map do |line|
              line = line.chomp
              line.start_with?("data:") ? line.delete_prefix("data:").strip : nil
            end
            next if data_lines.empty?

            data = data_lines.join("\n")
            yield data unless data.empty?
          end
        end

        producer.call(yield_chunk)

        return if buffer.strip.empty?

        data_lines = buffer.each_line.filter_map do |line|
          line = line.chomp
          line.start_with?("data:") ? line.delete_prefix("data:").strip : nil
        end
        data = data_lines.join("\n")
        yield data unless data.empty?
      end
    end
  end
end
