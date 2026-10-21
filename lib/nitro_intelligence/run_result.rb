require "nitro_intelligence/pending_review"

module NitroIntelligence
  # The outcome of one `/runs/wait`: either the run ended, possibly with a reply, or it paused on a
  # review.
  #
  # A paused run's last AI message is a draft awaiting review, never the reply, so `#reply` is nil
  # whenever the run paused. A reply is final only once a run ends without `__interrupt__`.
  class RunResult
    # The response exactly as Assistants returned it.
    attr_reader :raw

    def initialize(run)
      @raw = run.to_h
    end

    def interrupted?
      Array(raw["__interrupt__"]).any?
    end

    # What the paused run is waiting on, or nil when it did not pause.
    def review
      return @review if defined?(@review)

      @review = PendingReview.from_run(raw)
    end

    # The run's messages as Assistants reports them, oldest first.
    def messages
      Array(raw["messages"])
    end

    # The text of the run's final reply. Nil when the run paused, and when it ended without one: a
    # rejected or abandoned draft is removed from the conversation, leaving the human's message (or
    # a tool result) last, and an AI message that only calls tools says nothing to anyone.
    def reply
      return nil if interrupted?

      message = messages.last
      return nil if message.nil?
      return nil if message["type"].present? && message["type"] != "ai"

      content = message["content"]
      content.presence
    end
  end
end
