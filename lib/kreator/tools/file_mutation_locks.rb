# frozen_string_literal: true

module Kreator
  module Tools
    module FileMutationLocks
      @locks = {}
      @guard = Mutex.new

      module_function

      def with(path, &)
        lock = @guard.synchronize { @locks[path] ||= Mutex.new }
        lock.synchronize(&)
      end
    end
  end
end
