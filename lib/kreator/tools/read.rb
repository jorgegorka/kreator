# frozen_string_literal: true

module Kreator
  module Tools
    class Read
      DEFAULT_MAX_BYTES = 20_000
      DEFAULT_MAX_LINES = 200

      def name
        "read"
      end

      def description
        "Read a UTF-8 text file with optional line and byte truncation."
      end

      def schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["path"],
          "properties" => {
            "path" => { "type" => "string", "minLength" => 1 },
            "start_line" => { "type" => "integer", "minimum" => 1 },
            "max_lines" => { "type" => "integer", "minimum" => 1 },
            "max_bytes" => { "type" => "integer", "minimum" => 1 }
          }
        }
      end

      def call(args:, context:, signal:)
        path = resolve_path(args.fetch("path"), context)
        context.ensure_not_cancelled!(signal)
        start_line = args.fetch("start_line", 1)
        max_lines = args.fetch("max_lines", DEFAULT_MAX_LINES)
        max_bytes = args.fetch("max_bytes", DEFAULT_MAX_BYTES)

        bytes = File.binread(path, max_bytes + 1)
        byte_truncated = bytes.bytesize > max_bytes
        bytes = bytes.byteslice(0, max_bytes) if byte_truncated
        text = bytes.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\uFFFD")
        all_lines = text.lines
        selected_lines = all_lines.drop(start_line - 1).first(max_lines)
        line_truncated = all_lines.length >= start_line + max_lines
        content = selected_lines.join
        notices = []
        notices << "[truncated after #{max_bytes} bytes]" if byte_truncated
        notices << "[truncated after #{max_lines} lines]" if line_truncated
        content = "#{content}\n#{notices.join("\n")}" unless notices.empty?

        ToolResult.new(
          tool_call_id: "",
          name: name,
          content: content,
          metadata: {
            "path" => path,
            "bytes_read" => [bytes.bytesize, max_bytes].min,
            "byte_truncated" => byte_truncated,
            "line_truncated" => line_truncated
          }
        )
      end

      private

      def resolve_path(path, context)
        path = context.ensure_path_allowed!(context.resolve_path(path), action: :read)
        raise ArgumentError, "file does not exist: #{path}" unless File.file?(path)

        path
      end
    end
  end
end
