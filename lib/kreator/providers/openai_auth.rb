# frozen_string_literal: true

require "fileutils"
require "digest"
require "net/http"
require "rbconfig"
require "securerandom"
require "socket"
require "time"
require "uri"

module Kreator
  module Providers
    class OpenAIAuth
      CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
      AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
      DEFAULT_CODEX_HOME = File.expand_path("~/.codex")
      DEFAULT_REFRESH_URL = "https://auth.openai.com/oauth/token"
      DEFAULT_REDIRECT_URI = "http://localhost:1455/auth/callback"
      DEFAULT_LOGIN_TIMEOUT_SECONDS = 300
      REFRESH_INTERVAL_SECONDS = 8 * 24 * 60 * 60
      SCOPE = "openid profile email offline_access"

      DEFAULT_PI_AUTH_FILE = File.expand_path("~/.pi/agent/auth.json")

      attr_reader :mode, :token, :account_id, :plan_type, :auth_file

      def initialize(mode:, token:, **options)
        @mode = mode.to_sym
        @token = token.to_s
        @account_id = options[:account_id]
        @plan_type = options[:plan_type]
        @refresh_token = options[:refresh_token]
        @expires_at = options[:expires_at]
        @auth_file = options[:auth_file]
        @auth_json = options[:auth_json]
        @auth_provider = options[:auth_provider]
      end

      def self.resolve(api_key: nil, auth_file: ENV.fetch("KREATOR_OPENAI_AUTH_FILE", nil), codex_home: ENV.fetch("CODEX_HOME", DEFAULT_CODEX_HOME), allow_oauth: true)
        api_key_auth = resolve_api_key(api_key)
        return api_key_auth if api_key_auth

        auth_json, auth_file = find_auth_json(auth_file, codex_home)
        return nil unless auth_json && auth_file

        file_api_key_auth = resolve_auth_file_api_key(auth_json, auth_file)
        return file_api_key_auth if file_api_key_auth

        resolve_oauth(auth_json, auth_file, allow_oauth)
      end

      # rubocop:disable Metrics/ParameterLists
      def self.login(
        auth_file: ENV.fetch("KREATOR_OPENAI_AUTH_FILE", nil),
        codex_home: ENV.fetch("CODEX_HOME", DEFAULT_CODEX_HOME),
        open_browser: true,
        timeout: DEFAULT_LOGIN_TIMEOUT_SECONDS,
        on_auth: nil,
        signal: nil
      )
        resolved_auth_file = auth_file || File.join(codex_home, "auth.json")
        verifier, challenge = pkce_pair
        state = SecureRandom.hex(16)
        redirect_uri = ENV.fetch("OPENAI_OAUTH_REDIRECT_URI", DEFAULT_REDIRECT_URI)
        originator = ENV.fetch("OPENAI_OAUTH_ORIGINATOR", "kreator")
        authorization_url = authorization_url(challenge: challenge, state: state, redirect_uri: redirect_uri, originator: originator)
        server = OAuthCallbackServer.start(state: state, redirect_uri: redirect_uri)
        browser_opened = open_browser ? open_authorization_url(authorization_url) : false
        on_auth&.call(url: authorization_url, auth_file: resolved_auth_file, browser_opened: browser_opened)
        callback = wait_for_callback(server, timeout, signal)
        raise Error.new("OpenAI OAuth login timed out waiting for browser callback", code: "oauth_login_timeout") unless callback

        raise Error.new("OpenAI OAuth login cancelled", code: "cancelled") if aborted?(signal)

        token_response = exchange_authorization_code(callback.fetch(:code), verifier, redirect_uri)
        write_oauth_credentials(resolved_auth_file, token_response)
      ensure
        server&.close
      end
      # rubocop:enable Metrics/ParameterLists

      def self.logout(auth_file: ENV.fetch("KREATOR_OPENAI_AUTH_FILE", nil), codex_home: ENV.fetch("CODEX_HOME", DEFAULT_CODEX_HOME))
        path = auth_file || File.join(codex_home, "auth.json")
        auth_json = read_auth_json(path)
        return { removed: false, auth_file: path } unless auth_json

        removed = !auth_json.delete("openai-codex").nil?
        write_auth_json(path, auth_json) if removed
        { removed: removed, auth_file: path }
      end

      def self.resolve_oauth(auth_json, auth_file, allow_oauth)
        return nil unless allow_oauth

        pi_auth = resolve_pi_oauth(auth_json, auth_file)
        return pi_auth.refresh_if_stale if pi_auth

        resolve_codex_oauth(auth_json, auth_file)&.refresh_if_stale
      end

      def self.resolve_api_key(api_key)
        env_api_key = ENV["CODEX_API_KEY"].to_s.strip
        env_api_key = ENV["OPENAI_API_KEY"].to_s.strip if env_api_key.empty?
        resolved_api_key = api_key.to_s.strip
        resolved_api_key = env_api_key if resolved_api_key.empty?
        return nil if resolved_api_key.empty?

        new(mode: :api_key, token: resolved_api_key)
      end

      def self.find_auth_json(auth_file, codex_home)
        auth_candidates = auth_file ? [auth_file] : [File.join(codex_home, "auth.json"), DEFAULT_PI_AUTH_FILE]
        auth_candidates.each do |candidate|
          auth_json = read_auth_json(candidate)
          return [auth_json, candidate] if auth_json
        end

        nil
      end

      def self.resolve_auth_file_api_key(auth_json, auth_file)
        file_api_key = auth_json["OPENAI_API_KEY"].to_s.strip
        return nil if file_api_key.empty?
        return nil unless api_key_mode?(auth_json["auth_mode"].to_s)

        new(mode: :api_key, token: file_api_key, auth_file: auth_file, auth_json: auth_json)
      end

      def self.resolve_codex_oauth(auth_json, auth_file)
        tokens = auth_json["tokens"] || {}
        access_token = tokens["access_token"].to_s.strip
        return nil if access_token.empty?

        jwt_claims = jwt_claims(access_token)
        account_id = tokens["account_id"] || tokens["accountId"] || jwt_account_id(jwt_claims)
        plan_type = jwt_plan_type(jwt_claims)
        new(
          mode: :oauth,
          token: access_token,
          account_id: account_id,
          plan_type: plan_type,
          refresh_token: tokens["refresh_token"],
          auth_file: auth_file,
          auth_json: auth_json,
          auth_provider: :codex
        )
      end

      def self.resolve_pi_oauth(auth_json, auth_file)
        credential = auth_json["openai-codex"]
        return nil unless credential.is_a?(Hash) && credential["type"] == "oauth"

        access_token = credential["access"].to_s.strip
        return nil if access_token.empty?

        jwt_claims = jwt_claims(access_token)
        new(
          mode: :oauth,
          token: access_token,
          account_id: pi_account_id(credential, jwt_claims),
          plan_type: pi_plan_type(credential, jwt_claims),
          refresh_token: credential["refresh"],
          expires_at: credential["expires"],
          auth_file: auth_file,
          auth_json: auth_json,
          auth_provider: :pi
        )
      end

      def self.pi_account_id(credential, jwt_claims)
        credential["accountId"] || credential["account_id"] || jwt_account_id(jwt_claims)
      end

      def self.pi_plan_type(credential, jwt_claims)
        credential["planType"] || credential["plan_type"] || jwt_plan_type(jwt_claims)
      end

      def self.read_auth_json(path)
        return nil if path.to_s.empty? || !File.file?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError, SystemCallError => e
        raise Error, "failed to read OpenAI auth file #{path}: #{e.message}"
      end

      def self.api_key_mode?(auth_mode)
        normalized = auth_mode.gsub(/[^a-z]/i, "").downcase
        normalized.empty? || normalized == "apikey"
      end

      def self.jwt_claims(jwt)
        _header, payload, _signature = jwt.to_s.split(".", 3)
        return {} if payload.to_s.empty?

        payload = payload.tr("-_", "+/")
        payload += "=" * ((4 - (payload.length % 4)) % 4)
        JSON.parse(payload.unpack1("m0"))
      rescue ArgumentError, JSON::ParserError
        {}
      end

      def self.jwt_account_id(claims)
        auth_claims = claims["https://api.openai.com/auth"] || {}
        auth_claims["chatgpt_account_id"] || auth_claims["account_id"] || claims["account_id"]
      end

      def self.jwt_plan_type(claims)
        auth_claims = claims["https://api.openai.com/auth"] || {}
        auth_claims["chatgpt_plan_type"] || claims["chatgpt_plan_type"]
      end

      def self.authorization_url(challenge:, state:, redirect_uri:, originator:)
        uri = URI(AUTHORIZE_URL)
        uri.query = URI.encode_www_form(
          "response_type" => "code",
          "client_id" => CLIENT_ID,
          "redirect_uri" => redirect_uri,
          "scope" => SCOPE,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "state" => state,
          "id_token_add_organizations" => "true",
          "codex_cli_simplified_flow" => "true",
          "originator" => originator
        )
        uri.to_s
      end

      def self.pkce_pair
        verifier = base64_url(SecureRandom.random_bytes(32))
        challenge = base64_url(Digest::SHA256.digest(verifier))
        [verifier, challenge]
      end

      def self.exchange_authorization_code(code, verifier, redirect_uri)
        uri = URI(ENV.fetch("CODEX_REFRESH_TOKEN_URL_OVERRIDE", DEFAULT_REFRESH_URL))
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/x-www-form-urlencoded"
        request.set_form_data(
          "grant_type" => "authorization_code",
          "client_id" => CLIENT_ID,
          "code" => code,
          "code_verifier" => verifier,
          "redirect_uri" => redirect_uri
        )

        body = nil
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request) do |http_response|
            body = http_response.body.to_s
            http_response
          end
        end
        parsed = JSON.parse(body.to_s)
        unless response.is_a?(Net::HTTPSuccess) && parsed["access_token"] && parsed["refresh_token"]
          message = parsed.dig("error", "message") || parsed["error_description"] || body
          raise Error.new("OpenAI OAuth login failed: #{message}", code: "oauth_login_failed", status: response.code.to_i)
        end

        parsed
      rescue JSON::ParserError => e
        raise Error.new("OpenAI OAuth login returned invalid JSON: #{e.message}", code: "invalid_response")
      rescue Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError => e
        raise Error.new("OpenAI OAuth login failed: #{e.message}", code: "network_error", retryable: true)
      end

      def self.write_oauth_credentials(path, token_response)
        auth_json = read_auth_json(path) || {}
        access_token = token_response.fetch("access_token")
        expires_in = token_response["expires_in"].to_i
        credential = {
          "type" => "oauth",
          "access" => access_token,
          "refresh" => token_response.fetch("refresh_token")
        }
        credential["expires"] = ((Time.now.to_f * 1000) + (expires_in * 1000)).to_i if expires_in.positive?
        account_id = jwt_account_id(jwt_claims(access_token))
        plan_type = jwt_plan_type(jwt_claims(access_token))
        credential["accountId"] = account_id if account_id
        credential["planType"] = plan_type if plan_type
        auth_json["openai-codex"] = credential
        write_auth_json(path, auth_json)
        resolve(api_key: nil, auth_file: path, allow_oauth: true)
      end

      def self.open_authorization_url(url)
        command = case RbConfig::CONFIG["host_os"]
                  when /darwin/i
                    ["open", url]
                  when /mswin|mingw|cygwin/i
                    ["cmd", "/c", "start", "", url]
                  else
                    ["xdg-open", url]
                  end
        system(*command, out: File::NULL, err: File::NULL)
      rescue SystemCallError
        false
      end

      def self.write_auth_json(path, auth_json)
        temp_path = "#{path}.tmp"
        FileUtils.mkdir_p(File.dirname(path))
        File.write(temp_path, JSON.pretty_generate(auth_json), mode: "w", perm: 0o600)
        File.rename(temp_path, path)
      end

      def self.base64_url(value)
        [value].pack("m0").tr("+/", "-_").delete("=")
      end

      def self.wait_for_callback(server, timeout, signal)
        deadline = Time.now + timeout

        loop do
          raise Error.new("OpenAI OAuth login cancelled", code: "cancelled") if aborted?(signal)

          remaining = deadline - Time.now
          return nil unless remaining.positive?

          callback = server.wait([remaining, 0.1].min)
          return callback if callback
        end
      end

      def self.aborted?(signal)
        signal.respond_to?(:aborted?) && signal.aborted?
      end

      def oauth?
        mode == :oauth
      end

      def refreshable?
        oauth? && !@refresh_token.to_s.empty? && !auth_file.to_s.empty?
      end

      def refresh_if_stale
        return self unless refreshable?
        return self unless stale_refresh?

        refresh!
      end

      def refresh!
        response = request_token_refresh
        if @auth_provider == :pi
          update_pi_credentials(response)
        else
          update_codex_credentials(response)
        end

        write_auth_json
        self.class.resolve(api_key: nil, auth_file: auth_file, allow_oauth: true)
      end

      private

      def stale_refresh?
        return (Time.now.to_f * 1000) >= @expires_at.to_f if @auth_provider == :pi && @expires_at

        refreshed_at = Time.parse(@auth_json["last_refresh"].to_s)
        Time.now - refreshed_at >= REFRESH_INTERVAL_SECONDS
      rescue ArgumentError
        true
      end

      def update_pi_credentials(response)
        credential = (@auth_json["openai-codex"] ||= {})
        credential["type"] = "oauth"
        credential["access"] = response.fetch("access_token")
        credential["refresh"] = response["refresh_token"] unless response["refresh_token"].to_s.empty?
        expires_in = response["expires_in"].to_i
        credential["expires"] = ((Time.now.to_f * 1000) + (expires_in * 1000)).to_i if expires_in.positive?
        account_id = self.class.jwt_account_id(self.class.jwt_claims(response.fetch("access_token")))
        credential["accountId"] = account_id if account_id
      end

      def update_codex_credentials(response)
        tokens = (@auth_json["tokens"] ||= {})
        tokens["access_token"] = response.fetch("access_token")
        tokens["refresh_token"] = response["refresh_token"] unless response["refresh_token"].to_s.empty?
        tokens["id_token"] = response["id_token"] unless response["id_token"].to_s.empty?
        @auth_json["last_refresh"] = Time.now.utc.iso8601
      end

      def request_token_refresh
        uri = URI(ENV.fetch("CODEX_REFRESH_TOKEN_URL_OVERRIDE", DEFAULT_REFRESH_URL))
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/x-www-form-urlencoded"
        request.set_form_data(
          "grant_type" => "refresh_token",
          "client_id" => CLIENT_ID,
          "refresh_token" => @refresh_token
        )

        body = nil
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request) do |http_response|
            body = http_response.body.to_s
            http_response
          end
        end
        parsed = JSON.parse(body.to_s)
        unless response.is_a?(Net::HTTPSuccess) && parsed["access_token"]
          message = parsed.dig("error", "message") || parsed["error_description"] || body
          raise Error.new("OpenAI OAuth refresh failed: #{message}", code: "oauth_refresh_failed", status: response.code.to_i)
        end

        parsed
      rescue JSON::ParserError => e
        raise Error.new("OpenAI OAuth refresh returned invalid JSON: #{e.message}", code: "invalid_response")
      rescue Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError => e
        raise Error.new("OpenAI OAuth refresh failed: #{e.message}", code: "network_error", retryable: true)
      end

      def write_auth_json
        self.class.write_auth_json(auth_file, @auth_json)
      end

      class OAuthCallbackServer
        CALLBACK_PATH = "/auth/callback"

        def self.start(state:, redirect_uri:)
          uri = URI(redirect_uri)
          new(state: state, host: ENV.fetch("PI_OAUTH_CALLBACK_HOST", "127.0.0.1"), port: uri.port || 1455).tap(&:start)
        end

        def initialize(state:, host:, port:)
          @state = state
          @host = host
          @port = port
          @queue = Queue.new
        end

        def start
          @server = TCPServer.new(@host, @port)
          @thread = Thread.new { accept_callback }
          self
        rescue SystemCallError => e
          raise Error.new("failed to start OpenAI OAuth callback server on #{@host}:#{@port}: #{e.message}", code: "oauth_callback_server_failed")
        end

        def wait(timeout)
          @queue.pop(timeout: timeout)
        rescue ThreadError
          nil
        end

        def close
          @server&.close
          @thread&.kill
        rescue IOError
          nil
        end

        private

        def accept_callback
          socket = @server.accept
          request_line = socket.gets.to_s
          path = request_line.split[1].to_s
          uri = URI("http://localhost#{path}")
          response_status, response_body = process_callback(uri)
          socket.write "HTTP/1.1 #{response_status}\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n#{response_body}"
        ensure
          socket&.close
        end

        def process_callback(uri)
          return [404, html("OpenAI authentication callback route not found.")] unless uri.path == CALLBACK_PATH

          params = callback_params(uri)
          return [400, html("OpenAI authentication state mismatch.")] unless params["state"] == @state

          code = params["code"]
          return [400, html("OpenAI authentication callback is missing a code.")] if code.to_s.empty?

          @queue << { code: code }
          [200, html("OpenAI authentication completed. You can close this window.")]
        rescue URI::InvalidURIError
          [400, html("OpenAI authentication callback was invalid.")]
        end

        def callback_params(uri)
          return {} unless uri.query

          URI.decode_www_form(uri.query).to_h
        end

        def html(message)
          escaped = message.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
          "<!doctype html><html><body><h1>#{escaped}</h1></body></html>"
        end
      end
    end
  end
end
