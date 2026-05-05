# frozen_string_literal: true

module Kreator
  class Plugin
    attr_reader :path, :manifest

    def initialize(path:, manifest:)
      @path = File.expand_path(path)
      @manifest = manifest
    end

    def name
      manifest.fetch("name")
    end

    def version
      manifest["version"]
    end

    def description
      manifest["description"].to_s
    end

    def enabled?
      manifest.fetch("enabled", true)
    end

    def instructions_path
      File.join(path, "instructions.md")
    end

    def prompts_dir
      File.join(path, "prompts")
    end

    def skills_dir
      File.join(path, "skills")
    end

    def autoload_skill_names
      Array(manifest["autoload_skills"]).map(&:to_s)
    end

    def tool_specs
      Array(manifest["tools"])
    end

    def expand_path_inside!(relative_path)
      expanded = File.expand_path(relative_path, path)
      root = "#{path}#{File::SEPARATOR}"
      raise ArgumentError, "plugin path escapes plugin directory: #{relative_path}" unless expanded == path || expanded.start_with?(root)
      raise ArgumentError, "plugin file not found: #{expanded}" unless File.file?(expanded)

      expanded
    end

    def to_h
      {
        "name" => name,
        "version" => version,
        "description" => description,
        "path" => path,
        "enabled" => enabled?,
        "autoload_skills" => autoload_skill_names,
        "tools" => tool_specs
      }.compact
    end
  end
end
