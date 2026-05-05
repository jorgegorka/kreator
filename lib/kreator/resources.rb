# frozen_string_literal: true

module Kreator
  class Resources
    DEFAULT_HOME = File.expand_path("~/.kreator")

    ResourceFile = Struct.new(:name, :path, :content, keyword_init: true)

    attr_reader :cwd, :home_dir, :plugin_manager

    def initialize(cwd: Dir.pwd, home_dir: DEFAULT_HOME, plugin_manager: nil, plugins_enabled: true, plugin_names: nil)
      @cwd = File.expand_path(cwd)
      @home_dir = File.expand_path(home_dir)
      @plugin_manager = plugin_manager || PluginManager.new(
        cwd: @cwd,
        home_dir: @home_dir,
        enabled_names: plugin_names,
        plugins_enabled: plugins_enabled
      )
    end

    def system_prompt(base_prompt:, prompt: nil)
      sections = [base_prompt.to_s]
      sections << project_instruction_section
      sections << plugin_instruction_section
      sections << prompt_template_section
      sections << skill_index_section
      loaded = invoked_skills(prompt.to_s)
      sections << loaded_skill_section(loaded) unless loaded.empty?
      sections.compact.reject(&:empty?).join("\n\n")
    end

    def project_instructions
      paths = ancestor_dirs.flat_map do |directory|
        [
          File.join(directory, "AGENTS.md"),
          File.join(directory, ".kreator", "instructions.md")
        ]
      end
      paths.select { |path| File.file?(path) }
           .map { |path| ResourceFile.new(name: File.basename(path), path: path, content: File.read(path)) }
    end

    def prompt_templates
      merge_named_resources(global_prompt_templates, plugin_prompt_templates, project_prompt_templates)
    end

    def prompt_template(name)
      prompt_templates.find { |template| template.name == name.to_s }
    end

    def apply_prompt_template(name, prompt)
      template = prompt_template(name)
      raise ArgumentError, "prompt template not found: #{name}" unless template

      content = template.content
      return content.gsub("{{prompt}}", prompt.to_s) if content.include?("{{prompt}}")

      [content.rstrip, prompt.to_s].reject(&:empty?).join("\n\n")
    end

    def skills
      merge_named_resources(global_skills, plugin_skills, project_skills)
    end

    def skill(name)
      skills.find { |candidate| candidate.name == name.to_s }
    end

    def invoked_skills(prompt)
      skills.select { |candidate| skill_invoked?(candidate.name, prompt) }
    end

    def plugins
      plugin_manager.plugins
    end

    def plugin_tools
      PluginToolLoader.new.load_tools(plugins)
    end

    private

    def ancestor_dirs
      dirs = []
      current = cwd
      loop do
        dirs << current
        parent = File.dirname(current)
        break if parent == current

        current = parent
      end
      dirs.reverse
    end

    def global_prompt_templates
      templates_in(File.join(home_dir, "prompts"))
    end

    def project_prompt_templates
      ancestor_dirs.flat_map { |directory| templates_in(File.join(directory, ".kreator", "prompts")) }
    end

    def plugin_prompt_templates
      plugins.flat_map { |plugin| templates_in(plugin.prompts_dir) }
    end

    def templates_in(directory)
      return [] unless Dir.exist?(directory)

      Dir.glob(File.join(directory, "*.md")).map do |path|
        ResourceFile.new(name: File.basename(path, ".md"), path: path, content: File.read(path))
      end
    end

    def global_skills
      skills_in(File.join(home_dir, "skills"))
    end

    def project_skills
      ancestor_dirs.flat_map { |directory| skills_in(File.join(directory, ".kreator", "skills")) }
    end

    def plugin_skills
      plugins.flat_map { |plugin| skills_in(plugin.skills_dir) }
    end

    def skills_in(directory)
      return [] unless Dir.exist?(directory)

      Dir.glob(File.join(directory, "*", "SKILL.md")).map do |path|
        ResourceFile.new(name: File.basename(File.dirname(path)), path: path, content: File.read(path))
      end
    end

    def merge_named_resources(*groups)
      groups.flatten.to_h { |resource| [resource.name, resource] }.values
    end

    def project_instruction_section
      instructions = project_instructions
      return if instructions.empty?

      section(
        "Project Instructions",
        instructions.map { |file| "From #{file.path}:\n#{file.content.strip}" }.join("\n\n")
      )
    end

    def plugin_instruction_section
      files = plugins.filter_map do |plugin|
        next unless File.file?(plugin.instructions_path)

        ResourceFile.new(name: plugin.name, path: plugin.instructions_path, content: File.read(plugin.instructions_path))
      end
      return if files.empty?

      section(
        "Plugin Instructions",
        files.map { |file| "From #{file.path}:\n#{file.content.strip}" }.join("\n\n")
      )
    end

    def prompt_template_section
      templates = prompt_templates
      return if templates.empty?

      section(
        "Prompt Templates",
        templates.map { |template| "- #{template.name}: #{summary_for(template)}" }.join("\n")
      )
    end

    def skill_index_section
      all_skills = skills
      return if all_skills.empty?

      section(
        "Available Skills",
        all_skills.map { |candidate| "- #{candidate.name}: #{summary_for(candidate)}" }.join("\n")
      )
    end

    def loaded_skill_section(loaded)
      section(
        "Loaded Skills",
        loaded.map { |candidate| "Skill #{candidate.name} from #{candidate.path}:\n#{candidate.content.strip}" }.join("\n\n")
      )
    end

    def section(title, content)
      "#{title}:\n#{content}"
    end

    def summary_for(resource)
      resource.content.lines.map(&:strip).find { |line| !line.empty? && !line.start_with?("#") } || "No summary"
    end

    def skill_invoked?(name, prompt)
      prompt.match?(/(?:\$|@)#{Regexp.escape(name)}\b/) ||
        prompt.match?(/\bskill:#{Regexp.escape(name)}\b/i) ||
        prompt.match?(/\buse\s+#{Regexp.escape(name)}\s+skill\b/i)
    end
  end
end
