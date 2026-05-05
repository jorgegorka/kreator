# frozen_string_literal: true

require "test_helper"

class EventBusTest < Minitest::Test
  def test_publishes_to_specific_and_global_subscribers
    bus = Kreator::EventBus.new
    seen = []

    bus.subscribe("message_delta") { |event| seen << [:specific, event] }
    bus.subscribe { |event| seen << [:global, event] }

    bus.publish("message_delta", delta: "hi")

    assert_equal :specific, seen.fetch(0).fetch(0)
    assert_equal :global, seen.fetch(1).fetch(0)
    assert_equal "message_delta", seen.fetch(0).fetch(1).fetch(:type)
    assert_equal "hi", seen.fetch(1).fetch(1).fetch(:delta)
  end
end
