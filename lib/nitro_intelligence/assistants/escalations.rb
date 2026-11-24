require "json"
require "nitro_intelligence/escalation"

module NitroIntelligence
  # Escalations: reading the refusal of a run on an escalated thread, and resolving an
  # escalation. See `docs/ASSISTANTS.md`.
  class Assistants
    # Raised by {#run} when the thread is escalated to a person: Assistants refuses every run on it
    # while the escalation is open, and after it is closed. A RunError, so that callers rescuing
    # RunError still catch it. Pass the customer's message to whoever has the conversation.
    class ThreadEscalatedError < RunError
      # The escalation refusing the run: the stamp's summary, from the `409` or from the failure of a
      # run admitted before the thread was stamped; only its `id` and `status` when the failure
      # carries no summary. Its
      # `delivery&.status` says whether the application received the escalation.
      #
      # @return [Escalation, nil]
      attr_reader :escalation

      # @param message [String]
      # @param escalation [Escalation, nil]
      def initialize(message = nil, escalation: nil)
        super(message)
        @escalation = escalation
      end
    end

    # Raised by {#hand_back_escalation} and {#close_escalation} when Assistants refuses the
    # resolution, as it does a malformed one with a `422`. The message is the response body.
    class EscalationResolutionError < StandardError; end

    # Raised by {#hand_back_escalation} and {#close_escalation} when the thread has no open
    # escalation with that id: another person resolved it first, with a different decision, or it
    # never existed. An EscalationResolutionError.
    class EscalationNotOpenError < EscalationResolutionError
      # The thread's escalation as it stands, only its `id` and `status`; nil when the thread has
      # none.
      #
      # @return [Escalation, nil]
      attr_reader :escalation

      # @param message [String]
      # @param escalation [Escalation, nil]
      def initialize(message = nil, escalation: nil)
        super(message)
        @escalation = escalation
      end
    end

    # @api private
    # The `details.code` of a run refused because its thread is escalated.
    THREAD_ESCALATED = "thread_escalated".freeze

    # @api private
    # The `details.code` of a resolution of no open escalation.
    ESCALATION_NOT_OPEN = "escalation_not_open".freeze

    # @api private
    # The error of a run admitted before its thread was stamped, which fails instead of running.
    THREAD_ESCALATED_FAILURE = /thread_escalated: escalation (\S+) is (\w+)/

    # Hands an escalated conversation back to the assistant, from the person who had it. No run
    # starts: the person answered the customer while they had the conversation, and the customer's
    # next message starts an ordinary run.
    #
    # That run writes `note`, as a person's note, and then `messages` into the conversation, straight
    # after the escalation, so the assistant answers knowing what the person did and said. The same
    # hand-back sent again by the same `reviewer_id` is accepted as a retry.
    #
    # @param thread_id [String]
    # @param escalation_id [String] the open escalation's id ({Escalation#id})
    # @param reviewer_id [String] who resolved it, as the host identifies them
    # @param note [String, nil] up to 2,000 characters: what the person did, for the model
    # @param messages [Array<Hash>] what was said meanwhile, oldest first, each
    #   `{ "type" => "human" | "ai", "content" => "...", "name" => "..." }`, `name` optional
    # @param reviewed_at [Time, String, nil] when they resolved it. Defaults to now.
    # @return [Escalation] the handed-back escalation
    # @raise [ArgumentError] without an `escalation_id` or `reviewer_id`
    # @raise [EscalationNotOpenError] when the thread has no open escalation `escalation_id`
    # @raise [EscalationResolutionError] when Assistants refuses the hand-back
    # @example
    #   assistants.hand_back_escalation(thread_id:, escalation_id: escalation.id,
    #                                   reviewer_id: "jane@example.com",
    #                                   note: "Moved the visit to Friday at 9 by phone.")
    def hand_back_escalation(thread_id:, escalation_id:, reviewer_id:, note: nil, messages: [], reviewed_at: nil)
      decision = { type: "hand_back", note:, messages: Array(messages) }.compact
      resolve_escalation(thread_id:, escalation_id:, reviewer_id:, reviewed_at:, decision:)
    end

    # Closes an escalated conversation for good: the thread refuses every run after it.
    #
    # @param thread_id [String]
    # @param escalation_id [String] the open escalation's id ({Escalation#id})
    # @param reviewer_id [String] who closed it, as the host identifies them
    # @param reviewed_at [Time, String, nil] when they closed it. Defaults to now.
    # @return [Escalation] the closed escalation
    # @raise [ArgumentError] without an `escalation_id` or `reviewer_id`
    # @raise [EscalationNotOpenError] when the thread has no open escalation `escalation_id`
    # @raise [EscalationResolutionError] when Assistants refuses the close
    def close_escalation(thread_id:, escalation_id:, reviewer_id:, reviewed_at: nil)
      resolve_escalation(thread_id:, escalation_id:, reviewer_id:, reviewed_at:, decision: { type: "close" })
    end

  private

    def resolve_escalation(thread_id:, escalation_id:, reviewer_id:, reviewed_at:, decision:)
      raise ArgumentError, "escalation_id is required" if escalation_id.blank?
      raise ArgumentError, "reviewer_id is required" if reviewer_id.blank?

      body = { escalation_id:, decision:, **reviewer_stamp(reviewer_id, reviewed_at) }
      response = post(path: "/threads/#{thread_id}/escalation", body:)
      refused!(response, EscalationNotOpenError, ESCALATION_NOT_OPEN)
      Escalation.wrap(parse!(response, EscalationResolutionError)["escalation"])
    end

    # Raises `error`, carrying the escalation the refusal names, when `response` is a `409` for
    # `code`.
    def refused!(response, error, code)
      details = refusal(response, code)
      raise error.new(response.body, escalation: Escalation.wrap(details["escalation"])) if details
    end

    # The `details` of a `409` whose `details.code` is `code`, in Assistants' error shape
    # (`{"error", "message", "details"}`), or nil.
    def refusal(response, code)
      return nil unless response.code.to_i == CONFLICT_CODE

      details = JSON.parse(response.body.to_s)["details"]
      details.is_a?(Hash) && details["code"] == code ? details : nil
    rescue JSON::ParserError, TypeError
      nil
    end

    # Raises ThreadEscalatedError when a run's failure is a refusal on an escalated thread: a run
    # admitted before the thread was stamped. Its `details` carry the stamp's summary, or null when
    # the platform could not read the stamp, and then the `id` and `status` come from the message.
    def escalated_failure!(failure, detail)
      details = failure.is_a?(Hash) ? failure["details"] : nil
      return unless details.is_a?(Hash) && details["code"] == THREAD_ESCALATED

      named = detail.match(THREAD_ESCALATED_FAILURE)
      escalation = Escalation.wrap(details["escalation"])
      escalation ||= Escalation.new("id" => named[1], "status" => named[2]) if named
      raise ThreadEscalatedError.new(detail, escalation:)
    end
  end
end
