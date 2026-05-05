# frozen_string_literal: true

module Kreator
  class ToolContext
    DEFAULT_BASH_TIMEOUT = 30
    APPROVAL_POLICIES = %w[auto prompt deny].freeze
    INITIALIZE_OPTIONS = %i[
      cwd
      bash_timeout
      path_allowlist
      bash_deny_patterns
      bash_env
      approval_policy
      approval_callback
      plugin_approval_policy
      plugin_approval_callback
    ].freeze

    attr_reader :cwd, :bash_timeout, :path_allowlist, :bash_deny_patterns, :bash_env, :approval_policy,
                :plugin_approval_policy

    def initialize(**options)
      validate_initialize_options!(options)
      cwd = options.fetch(:cwd, Dir.pwd)
      @cwd = File.expand_path(cwd)
      bash_timeout = options.fetch(:bash_timeout, DEFAULT_BASH_TIMEOUT)
      @bash_timeout = Integer(bash_timeout)
      path_allowlist = options.fetch(:path_allowlist, nil)
      @path_allowlist = Array(path_allowlist || [@cwd]).map { |path| File.expand_path(path, @cwd) }
      bash_deny_patterns = options.fetch(:bash_deny_patterns, [])
      @bash_deny_patterns = Array(bash_deny_patterns).map { |pattern| Regexp.new(pattern.to_s) }
      bash_env = options.fetch(:bash_env, {})
      @bash_env = bash_env || {}
      approval_policy = options.fetch(:approval_policy, "auto")
      @approval_policy = approval_policy.to_s
      @approval_callback = options.fetch(:approval_callback, nil)
      plugin_approval_policy = options.fetch(:plugin_approval_policy, "prompt")
      @plugin_approval_policy = plugin_approval_policy.to_s
      @plugin_approval_callback = options.fetch(:plugin_approval_callback, nil)
      raise ArgumentError, "unknown approval policy: #{@approval_policy}" unless APPROVAL_POLICIES.include?(@approval_policy)
      return if APPROVAL_POLICIES.include?(@plugin_approval_policy)

      raise ArgumentError, "unknown plugin approval policy: #{@plugin_approval_policy}"
    end

    def resolve_path(path)
      File.expand_path(path, cwd)
    end

    def ensure_path_allowed!(path, action:)
      expanded = File.expand_path(path)
      allowed = path_allowlist.any? do |allowed_path|
        expanded == allowed_path || expanded.start_with?("#{allowed_path}#{File::SEPARATOR}")
      end
      return expanded if allowed

      raise ToolPermissionError.new(
        "#{action} denied outside allowed paths: #{expanded}",
        details: { "path" => expanded, "allowed_paths" => path_allowlist, "action" => action.to_s }
      )
    end

    def ensure_bash_allowed!(command)
      pattern = bash_deny_patterns.find { |candidate| command.match?(candidate) }
      return unless pattern

      raise ToolPermissionError.new(
        "bash command denied by policy: #{pattern.source}",
        details: { "command" => command, "pattern" => pattern.source }
      )
    end

    def approve!(action:, target:, details: {})
      approve_with_policy!(approval_policy, @approval_callback, action: action, target: target, details: details)
    end

    def approve_plugin_tool!(plugin:, tool:, description:, args:)
      approve_with_policy!(
        plugin_approval_policy,
        @plugin_approval_callback,
        action: :plugin_tool,
        target: tool,
        details: {
          "plugin" => plugin,
          "tool" => tool,
          "description" => description,
          "args" => args
        }
      )
    end

    def ensure_not_cancelled!(signal)
      return unless signal.respond_to?(:aborted?) && signal.aborted?

      raise ToolCancellationError
    end

    private

    def validate_initialize_options!(options)
      unknown = options.keys - INITIALIZE_OPTIONS
      return if unknown.empty?

      raise ArgumentError, "unknown keyword: #{unknown.first.inspect}"
    end

    def approve_with_policy!(policy, callback, action:, target:, details:)
      case policy
      when "auto"
        true
      when "deny"
        raise ToolPermissionError.new("#{action} denied by approval policy", details: details.merge("target" => target))
      when "prompt"
        approved = callback&.call(action: action.to_s, target: target, details: details)
        return true if approved

        raise ToolPermissionError.new("#{action} rejected", details: details.merge("target" => target))
      end
    end
  end
end
