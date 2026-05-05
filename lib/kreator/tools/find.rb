# frozen_string_literal: true

module Kreator
  module Tools
    class Find
      DEFAULT_MAX_RESULTS = 200

      def name
        "find"
      end

      def description
        "Find files and directories by name under an allowed path without shell predicates."
      end

      def schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "properties" => {
            "path" => { "type" => "string", "minLength" => 1 },
            "name" => { "type" => "string", "minLength" => 1 },
            "type" => { "type" => "string", "enum" => %w[file directory any] },
            "include_hidden" => { "type" => "boolean" },
            "max_results" => { "type" => "integer", "minimum" => 1 }
          }
        }
      end

      def call(args:, context:, signal:)
        root = allowed_path(args.fetch("path", "."), context)
        name_pattern = args["name"]
        type = args.fetch("type", "any")
        include_hidden = args.fetch("include_hidden", false)
        max_results = args.fetch("max_results", DEFAULT_MAX_RESULTS)
        matches = []

        each_path(root, include_hidden) do |path|
          context.ensure_not_cancelled!(signal)
          next unless type_match?(path, type)
          next unless name_match?(path, name_pattern)

          matches << relative_path(path, root)
          return result(root, matches, max_results) if matches.length > max_results
        end

        result(root, matches, max_results)
      end

      private

      def result(root, matches, max_results)
        visible_matches = matches.first(max_results)
        ToolResult.new(
          tool_call_id: "",
          name: name,
          content: visible_matches.empty? ? "(no matches)" : visible_matches.join("\n"),
          metadata: {
            "path" => root,
            "matches" => visible_matches.length,
            "result_truncated" => matches.length > max_results
          }
        )
      end

      def allowed_path(path, context)
        expanded = context.ensure_path_allowed!(context.resolve_path(path), action: :find)
        raise ArgumentError, "path does not exist: #{expanded}" unless File.exist?(expanded)

        expanded
      end

      def each_path(root, include_hidden, &)
        if File.directory?(root)
          visit_directory(root, root, include_hidden, &)
        else
          yield root
        end
      end

      def visit_directory(root, directory, include_hidden, &)
        directory_entries(directory).each do |entry|
          path = File.join(directory, entry)
          relative = relative_path(path, root)
          next unless visible_path?(relative, include_hidden)

          yield path
          visit_directory(root, path, include_hidden, &) if descend_into?(path)
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

      def descend_into?(path)
        File.directory?(path) && !File.symlink?(path)
      end

      def type_match?(path, type)
        case type
        when "file"
          File.file?(path)
        when "directory"
          File.directory?(path)
        else
          true
        end
      end

      def name_match?(path, name_pattern)
        return true unless name_pattern

        File.fnmatch?(name_pattern, File.basename(path), File::FNM_EXTGLOB)
      end

      def hidden_path?(relative)
        relative.split(File::SEPARATOR).any? { |part| part.start_with?(".") }
      end

      def relative_path(path, root)
        return File.basename(path) unless File.directory?(root)

        path.delete_prefix("#{root}#{File::SEPARATOR}")
      end
    end
  end
end
