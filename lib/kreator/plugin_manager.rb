# frozen_string_literal: true

require "json"
require "fileutils"

module Kreator
  class PluginManager
    MANIFEST_NAME = "plugin.json"
    DEFAULT_HOME = File.expand_path("~/.kreator")
    BUNDLED_PLUGINS_DIR = File.expand_path("bundled_plugins", __dir__)

    attr_reader :cwd, :home_dir, :enabled_names, :plugins_enabled

    def initialize(cwd: Dir.pwd, home_dir: DEFAULT_HOME, enabled_names: nil, plugins_enabled: true)
      @cwd = File.expand_path(cwd)
      @home_dir = File.expand_path(home_dir)
      @enabled_names = enabled_names&.map(&:to_s)
      @plugins_enabled = plugins_enabled
    end

    def plugins
      return [] unless plugins_enabled

      discovered = merge_plugins(plugin_dirs.filter_map { |path| load_plugin(path) })
      selected = discovered.select(&:enabled?)
      selected = selected.select { |plugin| enabled_names.include?(plugin.name) } if enabled_names
      selected
    end

    def plugin(name)
      plugins.find { |candidate| candidate.name == name.to_s }
    end

    def available_plugins
      Dir.glob(File.join(BUNDLED_PLUGINS_DIR, "*"))
         .select { |path| File.directory?(path) }
         .filter_map { |path| load_plugin(path) }
    end

    def validate(path_or_name)
      plugin = plugin(path_or_name) || available_plugin(path_or_name) || load_plugin(File.expand_path(path_or_name))
      raise ArgumentError, "plugin not found: #{path_or_name}" unless plugin

      errors = PluginToolLoader.new.validate(plugin)
      {
        "ok" => errors.empty?,
        "plugin" => plugin.to_h,
        "errors" => errors
      }
    end

    def install(path:, name: nil)
      source = source_path(path)
      plugin = load_plugin(source)
      raise ArgumentError, "invalid plugin: #{path}" unless plugin

      install_name = (name || plugin.name).to_s
      validate_plugin_name!(install_name)
      destination = File.join(home_dir, "plugins", install_name)
      raise ArgumentError, "plugin already installed: #{install_name}" if File.exist?(destination)

      validate(source).fetch("ok") || raise(ArgumentError, "plugin validation failed")
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp_r(source, destination)
      write_manifest_name(destination, install_name) if name
      load_plugin(destination)
    end

    def update(name:, path:)
      source = source_path(path)
      existing = File.join(home_dir, "plugins", name.to_s)
      raise ArgumentError, "plugin is not installed: #{name}" unless File.directory?(existing)
      raise ArgumentError, "invalid plugin: #{path}" unless load_plugin(source)

      validation = validate(source)
      raise ArgumentError, "plugin validation failed: #{validation.fetch('errors').join('; ')}" unless validation.fetch("ok")

      FileUtils.rm_rf(existing)
      FileUtils.mkdir_p(File.dirname(existing))
      FileUtils.cp_r(source, existing)
      write_manifest_name(existing, name.to_s)
      load_plugin(existing)
    end

    def remove(name)
      destination = File.join(home_dir, "plugins", name.to_s)
      raise ArgumentError, "plugin is not installed: #{name}" unless File.directory?(destination)

      FileUtils.rm_rf(destination)
      destination
    end

    private

    def available_plugin(name)
      available_plugins.find { |candidate| candidate.name == name.to_s }
    end

    def source_path(path_or_name)
      expanded = File.expand_path(path_or_name)
      return expanded if File.directory?(expanded)

      available_plugin(path_or_name)&.path || expanded
    end

    def validate_plugin_name!(name)
      return if name.match?(/\A[a-zA-Z0-9_-]+\z/)

      raise ArgumentError, "invalid plugin name: #{name}"
    end

    def plugin_dirs
      [
        Dir.glob(File.join(home_dir, "plugins", "*")),
        ancestor_dirs.flat_map { |directory| Dir.glob(File.join(directory, ".kreator", "plugins", "*")) }
      ].flatten.select { |path| File.directory?(path) }
    end

    def merge_plugins(plugins)
      plugins.to_h { |plugin| [plugin.name, plugin] }.values
    end

    def load_plugin(path)
      manifest_path = File.join(path, MANIFEST_NAME)
      return unless File.file?(manifest_path)

      manifest = JSON.parse(File.read(manifest_path))
      manifest["name"] ||= File.basename(path)
      Plugin.new(path: path, manifest: manifest)
    rescue JSON::ParserError, KeyError
      nil
    end

    def write_manifest_name(plugin_path, name)
      manifest_path = File.join(plugin_path, MANIFEST_NAME)
      manifest = JSON.parse(File.read(manifest_path))
      manifest["name"] = name
      File.write(manifest_path, "#{JSON.pretty_generate(manifest)}\n")
    end

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
  end
end
