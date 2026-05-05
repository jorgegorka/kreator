# frozen_string_literal: true

module Kreator
  module Tools
    class Ls
      DEFAULT_MAX_RESULTS = 200

      def name
        "ls"
      end

      def description
        "List directory entries with type and size metadata under an allowed path."
      end

      def schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "properties" => {
            "path" => { "type" => "string", "minLength" => 1 },
            "recursive" => { "type" => "boolean" },
            "include_hidden" => { "type" => "boolean" },
            "max_results" => { "type" => "integer", "minimum" => 1 }
          }
        }
      end

      def call(args:, context:, signal:)
        root = allowed_directory(args.fetch("path", "."), context)
        recursive = args.fetch("recursive", false)
        include_hidden = args.fetch("include_hidden", false)
        max_results = args.fetch("max_results", DEFAULT_MAX_RESULTS)
        entries = []

        traversal = {
          root: root,
          recursive: recursive,
          include_hidden: include_hidden,
          entries: entries,
          max_entries: max_results + 1,
          signal: signal,
          context: context
        }
        list_directory(root, traversal)
        visible_entries = entries.first(max_results)

        ToolResult.new(
          tool_call_id: "",
          name: name,
          content: visible_entries.empty? ? "(empty directory)" : format_entries(visible_entries),
          metadata: {
            "path" => root,
            "entries" => visible_entries,
            "count" => visible_entries.length,
            "result_truncated" => entries.length > max_results
          }
        )
      end

      private

      def allowed_directory(path, context)
        expanded = context.ensure_path_allowed!(context.resolve_path(path), action: :ls)
        raise ArgumentError, "directory does not exist: #{expanded}" unless File.exist?(expanded)
        raise ArgumentError, "not a directory: #{expanded}" unless File.directory?(expanded)

        expanded
      end

      def list_directory(directory, traversal)
        visible_entries(directory, traversal) do |path, relative|
          traversal.fetch(:entries) << entry_for(path, relative)
          return if entry_limit_reached?(traversal)

          list_directory(path, traversal) if descend_into?(path, traversal)
          return if entry_limit_reached?(traversal)
        end
      end

      def visible_entries(directory, traversal)
        directory_entries(directory).each do |entry|
          traversal.fetch(:context).ensure_not_cancelled!(traversal.fetch(:signal))
          path = File.join(directory, entry)
          relative = path.delete_prefix("#{traversal.fetch(:root)}#{File::SEPARATOR}")
          yield path, relative if visible_path?(relative, traversal.fetch(:include_hidden))
        end
      end

      def directory_entries(directory)
        Dir.children(directory).sort
      rescue SystemCallError
        []
      end

      def visible_path?(relative, include_hidden)
        include_hidden || !hidden_path?(relative)
      end

      def descend_into?(path, traversal)
        traversal.fetch(:recursive) && File.directory?(path) && !File.symlink?(path)
      end

      def entry_limit_reached?(traversal)
        traversal.fetch(:entries).length >= traversal.fetch(:max_entries)
      end

      def entry_for(path, relative)
        {
          "path" => relative,
          "type" => type_for(path),
          "size" => size_for(path)
        }
      end

      def type_for(path)
        return "symlink" if File.symlink?(path)
        return "directory" if File.directory?(path)
        return "file" if File.file?(path)

        "other"
      end

      def size_for(path)
        File.file?(path) ? File.size(path) : nil
      rescue SystemCallError
        nil
      end

      def hidden_path?(relative)
        relative.split(File::SEPARATOR).any? { |part| part.start_with?(".") }
      end

      def format_entries(entries)
        entries.map do |entry|
          size = entry["size"].nil? ? "-" : entry["size"]
          "#{entry.fetch('path')}\t#{entry.fetch('type')}\t#{size}"
        end.join("\n")
      end
    end
  end
end
