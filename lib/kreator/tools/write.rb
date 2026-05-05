# frozen_string_literal: true

require "fileutils"

module Kreator
  module Tools
    class Write
      def name
        "write"
      end

      def description
        "Write complete UTF-8 text contents to a file, creating parent directories."
      end

      def schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "required" => %w[path content],
          "properties" => {
            "path" => { "type" => "string", "minLength" => 1 },
            "content" => { "type" => "string" }
          }
        }
      end

      def call(args:, context:, signal:)
        path = File.expand_path(args.fetch("path"), context.cwd)
        content = args.fetch("content")

        FileMutationLocks.with(path) do
          existed = File.exist?(path)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
          ToolResult.new(
            tool_call_id: "",
            name: name,
            content: "wrote #{content.bytesize} bytes to #{path}",
            metadata: { "path" => path, "created" => !existed, "bytes_written" => content.bytesize }
          )
        end
      end
    end
  end
end
