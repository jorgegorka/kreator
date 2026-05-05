# frozen_string_literal: true

module Kreator
  class EventBus
    def initialize
      @subscribers = Hash.new { |hash, key| hash[key] = [] }
      @all_subscribers = []
    end

    def subscribe(type = nil, &block)
      raise ArgumentError, "block required" unless block

      if type
        @subscribers[type.to_s] << block
      else
        @all_subscribers << block
      end

      block
    end
    alias on subscribe

    def unsubscribe(*args)
      type, subscriber = unsubscribe_args(args)

      if type
        @subscribers[type.to_s].delete(subscriber)
      else
        @all_subscribers.delete(subscriber)
      end
    end

    def publish(type, payload = {})
      event = payload.merge(type: type.to_s)
      @subscribers[type.to_s].each { |subscriber| subscriber.call(event) }
      @all_subscribers.each { |subscriber| subscriber.call(event) }
      event
    end

    private

    def unsubscribe_args(args)
      case args.length
      when 1
        [nil, args.first]
      when 2
        args
      else
        raise ArgumentError, "wrong number of arguments (given #{args.length}, expected 1..2)"
      end
    end
  end
end
