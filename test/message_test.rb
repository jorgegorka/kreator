# frozen_string_literal: true

require "test_helper"

class MessageTest < Minitest::Test
  def test_serializes_message_with_tool_calls
    call = Kreator::ToolCall.new(id: "call_1", name: "read", arguments: { "path" => "README.md" })
    message = Kreator::Message.assistant("I will read it.", tool_calls: [call])

    assert_equal(
      {
        "role" => "assistant",
        "content" => "I will read it.",
        "tool_calls" => [
          {
            "id" => "call_1",
            "name" => "read",
            "arguments" => { "path" => "README.md" },
            "metadata" => {}
          }
        ],
        "metadata" => {}
      },
      message.to_h
    )
  end

  def test_rejects_unknown_roles
    assert_raises(ArgumentError) do
      Kreator::Message.new(role: "developer", content: "Nope")
    end
  end
end
