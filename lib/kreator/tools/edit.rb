# frozen_string_literal: true

require "diff/lcs"
require "diff/lcs/hunk"

module Kreator
  module Tools
    class Edit
      def name
        "edit"
      end

      def description
        "Apply an exact text replacement to a file and return a unified diff."
      end

      def schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "required" => %w[path old_string new_string],
          "properties" => {
            "path" => { "type" => "string", "minLength" => 1 },
            "old_string" => { "type" => "string", "minLength" => 1 },
            "new_string" => { "type" => "string" },
            "replace_all" => { "type" => "boolean" }
          }
        }
      end

      def call(args:, context:, signal:)
        path = context.ensure_path_allowed!(context.resolve_path(args.fetch("path")), action: :edit)
        old_string = args.fetch("old_string")
        new_string = args.fetch("new_string")
        replace_all = args.fetch("replace_all", false)
        context.approve!(
          action: :edit,
          target: path,
          details: { "replace_all" => replace_all }
        )
        context.ensure_not_cancelled!(signal)

        FileMutationLocks.with(path) do
          original = File.read(path)
          occurrences = original.scan(old_string).length
          raise ArgumentError, "old_string was not found in #{path}" if occurrences.zero?
          raise ArgumentError, "old_string occurs #{occurrences} times; pass replace_all=true to replace all" if occurrences > 1 && !replace_all

          updated = replace_all ? original.gsub(old_string, new_string) : original.sub(old_string, new_string)
          context.ensure_not_cancelled!(signal)
          File.write(path, updated)
          diff = unified_diff(original, updated, path)

          ToolResult.new(
            tool_call_id: "",
            name: name,
            content: diff,
            metadata: { "path" => path, "replacements" => replace_all ? occurrences : 1 }
          )
        end
      end

      private

      def unified_diff(original, updated, path)
        old_lines = original.lines
        new_lines = updated.lines
        pieces = Diff::LCS.diff(old_lines, new_lines)
        return "" if pieces.empty?

        output = "--- #{path}\n+++ #{path}\n"
        file_length_difference = 0
        pieces.each do |piece|
          hunk = Diff::LCS::Hunk.new(old_lines, new_lines, piece, 3, file_length_difference)
          file_length_difference = hunk.file_length_difference
          output << hunk.diff(:unified)
        end
        output
      end
    end
  end
end
