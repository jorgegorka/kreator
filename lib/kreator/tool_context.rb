# frozen_string_literal: true

module Kreator
  class ToolContext
    DEFAULT_BASH_TIMEOUT = 30

    attr_reader :cwd, :bash_timeout

    def initialize(cwd: Dir.pwd, bash_timeout: DEFAULT_BASH_TIMEOUT)
      @cwd = File.expand_path(cwd)
      @bash_timeout = Integer(bash_timeout)
    end
  end
end
