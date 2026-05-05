# frozen_string_literal: true

module Kreator
  class CancellationSignal
    def initialize
      @mutex = Mutex.new
      @aborted = false
    end

    def abort!
      @mutex.synchronize { @aborted = true }
    end

    def aborted?
      @mutex.synchronize { @aborted }
    end
  end
end
