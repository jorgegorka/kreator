# frozen_string_literal: true

module Kreator
  class Compactor
    DEFAULT_THRESHOLD = 24_000
    DEFAULT_KEEP_LAST = 8

    def self.should_compact?(messages, threshold: DEFAULT_THRESHOLD)
      return false unless threshold

      messages.sum { |message| message.content.length } > threshold.to_i
    end

    def self.compact(messages, keep_last: DEFAULT_KEEP_LAST)
      normalized = messages.map { |message| message.is_a?(Message) ? message : Message.from_h(message) }
      kept = normalized.last(keep_last)
      compacted_count = normalized.length - kept.length
      summary = summary_for(normalized.first(compacted_count))
      [Message.system(summary), kept].flatten
    end

    def self.summary_for(messages)
      counts = messages.group_by(&:role).transform_values(&:length)
      excerpts = messages.last(6).map do |message|
        content = message.content.gsub(/\s+/, " ").strip
        content = "#{content[0, 180]}..." if content.length > 180
        "- #{message.role}: #{content}"
      end

      [
        "Earlier conversation was compacted locally.",
        "Message counts: #{counts.sort.map { |role, count| "#{role}=#{count}" }.join(', ')}.",
        "Recent compacted excerpts:",
        excerpts.join("\n")
      ].join("\n")
    end
  end
end
