# frozen_string_literal: true

module Kreator
  module Tools
    class Grep
      DEFAULT_MAX_RESULTS = 100
      DEFAULT_MAX_BYTES = 20_000
      BINARY_SAMPLE_BYTES = 4096

      def name
        "grep"
      end

      def description
        "Search UTF-8 text files for a Ruby regular expression with path allowlist checks and truncation."
      end

      def schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["pattern"],
          "properties" => {
            "pattern" => { "type" => "string", "minLength" => 1 },
            "path" => { "type" => "string", "minLength" => 1 },
            "case_sensitive" => { "type" => "boolean" },
            "include_hidden" => { "type" => "boolean" },
            "glob" => { "type" => "string", "minLength" => 1 },
            "max_results" => { "type" => "integer", "minimum" => 1 },
            "max_bytes" => { "type" => "integer", "minimum" => 1 }
          }
        }
      end

      def call(args:, context:, signal:)
        root = allowed_path(args.fetch("path", "."), context)
        pattern = compile_pattern(args.fetch("pattern"), args.fetch("case_sensitive", true))
        include_hidden = args.fetch("include_hidden", false)
        glob = args["glob"]
        max_results = args.fetch("max_results", DEFAULT_MAX_RESULTS)
        max_bytes = args.fetch("max_bytes", DEFAULT_MAX_BYTES)
        matches = []
        scanned = 0

        candidate_files(root, include_hidden, glob).each do |path|
          context.ensure_not_cancelled!(signal)
          next if binary_file?(path)

          scanned += 1
          grep_file(path, root, pattern, matches, max_results + 1)
          break if matches.length > max_results
        end

        visible_matches = matches.first(max_results)
        result_truncated = matches.length > max_results
        content, byte_truncated = truncate_content(format_matches(visible_matches), max_bytes)
        ToolResult.new(
          tool_call_id: "",
          name: name,
          content: content.empty? ? "(no matches)" : content,
          metadata: {
            "path" => root,
            "scanned_files" => scanned,
            "matches" => visible_matches.length,
            "result_truncated" => result_truncated,
            "byte_truncated" => byte_truncated
          }
        )
      end

      private

      def allowed_path(path, context)
        expanded = context.ensure_path_allowed!(context.resolve_path(path), action: :grep)
        raise ArgumentError, "path does not exist: #{expanded}" unless File.exist?(expanded)

        expanded
      end

      def compile_pattern(pattern, case_sensitive)
        options = case_sensitive ? 0 : Regexp::IGNORECASE
        Regexp.new(pattern, options)
      rescue RegexpError => e
        raise ToolError.new("invalid grep pattern: #{e.message}", code: "validation_error")
      end

      def candidate_files(root, include_hidden, glob)
        paths = File.file?(root) ? [root] : recursive_paths(root, include_hidden)
        paths.select do |path|
          File.file?(path) && !File.symlink?(path) && glob_match?(relative_path(path, root), glob)
        end
      end

      def recursive_paths(root, include_hidden)
        results = []
        visit_directory(root, root, include_hidden, results)
        results
      end

      def visit_directory(root, directory, include_hidden, results)
        directory_entries(directory).each do |entry|
          path = File.join(directory, entry)
          relative = relative_path(path, root)
          next unless visible_path?(relative, include_hidden)

          results << path
          visit_directory(root, path, include_hidden, results) if descend_into?(path)
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

      def grep_file(path, root, pattern, matches, max_matches)
        text = File.binread(path).encode("UTF-8", invalid: :replace, undef: :replace, replace: "\uFFFD")
        text.lines.each.with_index(1) do |line, line_number|
          next unless line.match?(pattern)

          matches << {
            "path" => relative_path(path, root),
            "line" => line_number,
            "text" => line.chomp
          }
          break if matches.length >= max_matches
        end
      rescue SystemCallError, ArgumentError
        nil
      end

      def binary_file?(path)
        File.open(path, "rb") { |file| file.read(BINARY_SAMPLE_BYTES).to_s.include?("\x00") }
      rescue SystemCallError
        true
      end

      def glob_match?(relative, glob)
        return true unless glob

        flags = File::FNM_PATHNAME | File::FNM_EXTGLOB
        File.fnmatch?(glob, relative, flags) || File.fnmatch?(glob, File.basename(relative), flags)
      end

      def hidden_path?(relative)
        relative.split(File::SEPARATOR).any? { |part| part.start_with?(".") }
      end

      def relative_path(path, root)
        root_path = File.file?(root) ? File.dirname(root) : root
        relative = path.delete_prefix("#{root_path}#{File::SEPARATOR}")
        relative.empty? ? File.basename(path) : relative
      end

      def format_matches(matches)
        matches.map { |match| "#{match.fetch('path')}:#{match.fetch('line')}:#{match.fetch('text')}" }.join("\n")
      end

      def truncate_content(content, max_bytes)
        return [content, false] if content.bytesize <= max_bytes

        ["#{content.byteslice(0, max_bytes)}\n[truncated after #{max_bytes} bytes]", true]
      end
    end
  end
end
