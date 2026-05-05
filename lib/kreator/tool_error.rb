# frozen_string_literal: true

module Kreator
  class ToolError < StandardError
    attr_reader :code, :details

    def initialize(message, code: "runtime_error", details: {})
      super(message)
      @code = code.to_s
      @details = details || {}
    end

    def to_h
      {
        "code" => code,
        "class" => self.class.name,
        "message" => message,
        "details" => details
      }
    end
  end

  class ToolPermissionError < ToolError
    def initialize(message, details: {})
      super(message, code: "permission_denied", details: details)
    end
  end

  class ToolCancellationError < ToolError
    def initialize(message = "tool execution cancelled", details: {})
      super(message, code: "cancelled", details: details)
    end
  end
end
