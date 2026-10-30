require "nitro_intelligence/pending_review"

module NitroIntelligence
  # The outcome of one `/runs/wait`: either the run ended, possibly with a reply, or it paused on a
  # review.
  #
  # A run has at most one reply: its final message, an AI message with text and no tool calls. Text
  # the model writes alongside tool calls is working text, never the reply. A paused run's last AI
  # message is a draft awaiting review, so `#reply` is nil whenever the run paused; a reply is final
  # only once a run ends without `__interrupt__`.
  class RunResult
    # How the platform delivered the reply through the assistant's delivery tool, read from the
    # reply's `response_metadata.delivery` stamp. `status` is "delivered" (with `result`, what the
    # tool returned, and `delivered_at`), "failed" (with the tool's `error` and `failed_at`), or
    # "pending": the platform stamps a settled reply "pending" just before it delivers it, so a
    # finished run still showing it was cut off before delivery recorded an outcome. Treat a
    # pending reply as not sent; the next customer message removes it and the model answers both. A
    # field the stamp does not carry, or carries as the wrong type, is nil.
    #
    # @!attribute [r] status
    #   @return [String, nil] `"delivered"`, `"failed"` or `"pending"`
    # @!attribute [r] tool
    #   @return [String, nil] the delivery tool's name
    # @!attribute [r] attempts
    #   @return [Integer, nil] how many times the platform called the tool
    # @!attribute [r] error
    #   @return [String, nil] the tool's error, when delivery failed
    # @!attribute [r] result
    #   @return [Object, nil] what the tool returned, when it succeeded
    # @!attribute [r] delivered_at
    #   @return [String, nil] when the reply was delivered, as an ISO 8601 timestamp
    # @!attribute [r] failed_at
    #   @return [String, nil] when delivery gave up, as an ISO 8601 timestamp
    Delivery = Struct.new(:status, :tool, :attempts, :error, :result, :delivered_at, :failed_at,
                          keyword_init: true) do
      # @return [Boolean] whether the platform delivered the reply
      def delivered?
        status == "delivered"
      end

      # @return [Boolean] whether delivery failed
      def failed?
        status == "failed"
      end

      # @return [Boolean] whether delivery was cut off before it recorded an outcome
      def pending?
        status == "pending"
      end
    end

    # @api private
    # The `response_metadata.review` type the platform stamps on a draft when it pauses on it.
    PENDING_REVIEW = "pending".freeze

    # The response exactly as Assistants returned it.
    #
    # @return [Hash]
    attr_reader :raw

    # @api private
    def initialize(run)
      @raw = run.to_h
    end

    # @return [Boolean] whether the run paused for review
    def interrupted?
      Array(raw["__interrupt__"]).any?
    end

    # What the paused run is waiting on, or nil when it did not pause.
    #
    # @return [PendingReview, nil]
    def review
      return @review if defined?(@review)

      @review = PendingReview.from_run(raw)
    end

    # The run's messages as Assistants reports them, oldest first.
    #
    # @return [Array<Hash>]
    def messages
      Array(raw["messages"])
    end

    # The text of the run's reply, always a String: content given as blocks is reduced to its text.
    # Nil while the run is paused, and when it ended without one: a rejected draft is removed,
    # leaving a tool result or the human's message last, and an earlier turn's text is never the
    # reply. Blank text is no reply.
    #
    # @return [String, nil]
    def reply
      reply_message && text(reply_message["content"]).presence
    end

    # The reply's delivery, or nil when the reply carries no delivery stamp: no reply, or no
    # delivery tool configured for the assistant.
    #
    # @return [Delivery, nil]
    def delivery
      return @delivery if defined?(@delivery)

      stamp = reply_message&.dig("response_metadata", "delivery")
      @delivery = stamp.is_a?(Hash) ? build_delivery(stamp) : nil
    end

  private

    # The run's last message, when the run ended and that message is the assistant's reply: an AI
    # message with no tool calls. A draft still stamped as awaiting review is never the reply, even
    # in a response that reports no pause.
    def reply_message
      return nil if interrupted?

      message = messages.last
      return nil unless message.is_a?(Hash)
      return nil if message["type"].present? && message["type"] != "ai"
      return nil if Array(message["tool_calls"]).any?
      return nil if awaiting_review?(message)

      message
    end

    def awaiting_review?(message)
      review = message.dig("response_metadata", "review")
      review.is_a?(Hash) && review["type"] == PENDING_REVIEW
    end

    # A message's content is a string, or a list of content blocks. Its text is the string, or the
    # bare strings and `text` blocks joined, as the platform reads it (LangChain's `message.text`);
    # other blocks -- tool use, reasoning, images -- are not part of the reply.
    def text(content)
      return content if content.is_a?(String)
      return nil unless content.is_a?(Array)

      content.filter_map do |block|
        next block if block.is_a?(String)

        block["text"] if block.is_a?(Hash) && block["type"] == "text" && block["text"].is_a?(String)
      end.join
    end

    def build_delivery(stamp)
      Delivery.new(
        status: string_or_nil(stamp["status"]),
        tool: string_or_nil(stamp["tool"]),
        attempts: stamp["attempts"].is_a?(Integer) ? stamp["attempts"] : nil,
        error: string_or_nil(stamp["error"]),
        result: stamp["result"],
        delivered_at: string_or_nil(stamp["delivered_at"]),
        failed_at: string_or_nil(stamp["failed_at"])
      )
    end

    def string_or_nil(value)
      value.is_a?(String) ? value : nil
    end
  end
end
