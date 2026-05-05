# frozen_string_literal: true

require "fileutils"
require "test_helper"
require "tmpdir"

class ResourcesTest < Minitest::Test
  def test_discovers_project_instructions_templates_and_invoked_skills
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "AGENTS.md"), "Follow project rules.")
      FileUtils.mkdir_p(File.join(dir, ".kreator", "prompts"))
      File.write(File.join(dir, ".kreator", "prompts", "review.md"), "Review this:\n{{prompt}}")
      FileUtils.mkdir_p(File.join(dir, ".kreator", "skills", "rails"))
      File.write(File.join(dir, ".kreator", "skills", "rails", "SKILL.md"), "# Rails\nUse Rails conventions.")

      resources = Kreator::Resources.new(cwd: dir, home_dir: File.join(dir, "home"))

      assert_equal ["AGENTS.md"], resources.project_instructions.map(&:name)
      assert_equal "Review this:\ncontrollers", resources.apply_prompt_template("review", "controllers")
      assert_equal ["rails"], resources.invoked_skills("Use $rails here").map(&:name)

      system_prompt = resources.system_prompt(base_prompt: "Base.", prompt: "Use $rails here")

      assert_includes system_prompt, "Follow project rules."
      assert_includes system_prompt, "Prompt Templates:"
      assert_includes system_prompt, "Available Skills:"
      assert_includes system_prompt, "Use Rails conventions."
    end
  end

  def test_plugins_contribute_instructions_templates_and_skills
    Dir.mktmpdir do |dir|
      plugin_dir = File.join(dir, "home", "plugins", "reviewer")
      FileUtils.mkdir_p(File.join(plugin_dir, "prompts"))
      FileUtils.mkdir_p(File.join(plugin_dir, "skills", "audit"))
      File.write(File.join(plugin_dir, "plugin.json"), JSON.generate("name" => "reviewer", "description" => "Review helpers"))
      File.write(File.join(plugin_dir, "instructions.md"), "Plugin instruction.")
      File.write(File.join(plugin_dir, "prompts", "audit.md"), "Audit: {{prompt}}")
      File.write(File.join(plugin_dir, "skills", "audit", "SKILL.md"), "# Audit\nCheck carefully.")

      resources = Kreator::Resources.new(cwd: dir, home_dir: File.join(dir, "home"))

      assert_equal ["reviewer"], resources.plugins.map(&:name)
      assert_equal "Audit: controllers", resources.apply_prompt_template("audit", "controllers")
      assert_equal ["audit"], resources.invoked_skills("Use $audit").map(&:name)

      system_prompt = resources.system_prompt(base_prompt: "Base.", prompt: "Use $audit")

      assert_includes system_prompt, "Plugin Instructions:"
      assert_includes system_prompt, "Plugin instruction."
      assert_includes system_prompt, "Check carefully."
    end
  end

  def test_plugins_can_autoload_skills
    Dir.mktmpdir do |dir|
      plugin_dir = File.join(dir, "home", "plugins", "rails")
      FileUtils.mkdir_p(File.join(plugin_dir, "skills", "rails"))
      File.write(
        File.join(plugin_dir, "plugin.json"),
        JSON.generate("name" => "rails", "autoload_skills" => ["rails"])
      )
      File.write(File.join(plugin_dir, "skills", "rails", "SKILL.md"), "# Rails\nPrefer Rails conventions.")

      resources = Kreator::Resources.new(cwd: dir, home_dir: File.join(dir, "home"))
      system_prompt = resources.system_prompt(base_prompt: "Base.", prompt: "No explicit skill invocation")

      assert_includes system_prompt, "Loaded Skills:"
      assert_includes system_prompt, "Prefer Rails conventions."
    end
  end

  def test_can_disable_or_filter_plugins
    Dir.mktmpdir do |dir|
      %w[first second].each do |name|
        plugin_dir = File.join(dir, "home", "plugins", name)
        FileUtils.mkdir_p(plugin_dir)
        File.write(File.join(plugin_dir, "plugin.json"), JSON.generate("name" => name))
      end

      disabled = Kreator::Resources.new(cwd: dir, home_dir: File.join(dir, "home"), plugins_enabled: false)
      filtered = Kreator::Resources.new(cwd: dir, home_dir: File.join(dir, "home"), plugin_names: ["second"])

      assert_empty disabled.plugins
      assert_equal ["second"], filtered.plugins.map(&:name)
    end
  end
end
