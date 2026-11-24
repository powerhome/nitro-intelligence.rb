require "json"
require "nitro_intelligence/escalation"
require "nitro_intelligence/run_result"

module NitroIntelligence
  # Escalations: reading the refusal of a run on an escalated thread, and resolving an
  # escalation. See `docs/ASSISTANTS.md`.
  class Assistants
    # Raised by {#run} when the thread is escalated to a person: Assistants refuses every run on it
    # while the escalation is open, and after it is closed. A RunError, so that callers rescuing
    # RunError still catch it. Pass the customer's message to whoever has the conversation.
    class ThreadEscalatedError < RunError
      # The escalation refusing the run: the stamp's summary from the `409`, or only its `id` and
      # `status` when a run admitted before the thread was stamped failed instead. Its
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
    # What Assistants answers a refused run or resolution with, its `details.code` saying why.
    CONFLICT_CODE = 409

    # @api private
    # The `details.code` of a run refused because its thread is escalated.
    THREAD_ESCALATED = "thread_escalated".freeze

    # @api private
    # The `details.code` of a resolution of no open escalation.
    ESCALATION_NOT_OPEN = "escalation_not_open".freeze

    # @api private
    # The error of a run admitted before its thread was stamped, which fails instead of running.
    THREAD_ESCALATED_FAILURE = /thread_escalated: escalation (\S+) is (\w+)/

    # Hands an escalated conversation back to the assistant, from the person who had it. By
    # default the assistant answers at once, and this returns that run's RunResult, as {#run}
    # does; the reply goes through the judge, review and delivery as usual. With `reply: false`, it
    # returns the resolved Escalation, and the customer's next message starts an ordinary run.
    #
    # The next run writes `note`, as a person's note, and then `messages` into the conversation,
    # straight after the escalation. The same hand-back sent again by the same `reviewer_id` is
    # accepted as a retry; one sent after its reply run started starts no second one, and returns
    # the Escalation instead.
    #
    # @param thread_id [String]
    # @param assistant_id [String] the assistant whose thread it is, which answers
    # @param escalation_id [String] the open escalation's id ({Escalation#id})
    # @param reviewer_id [String] who resolved it, as the host identifies them
    # @param note [String, nil] up to 2,000 characters, for the model
    # @param messages [Array<Hash>] what was said meanwhile, oldest first, each
    #   `{ "type" => "human" | "ai", "content" => "...", "name" => "..." }`, `name` optional
    # @param reply [Boolean] whether the assistant answers now
    # @param context [Hash] the reply run's context, as for {#run}: send what you send when you
    #   start a run on the thread
    # @param reviewed_at [Time, String, nil] when they resolved it. Defaults to now.
    # @return [RunResult, Escalation] the reply run; the Escalation without one
    # @raise [ArgumentError] without an `escalation_id` or `reviewer_id`
    # @raise [EscalationNotOpenError] when the thread has no open escalation `escalation_id`
    # @raise [EscalationResolutionError] when Assistants refuses the hand-back
    # @raise [RunError] when the reply run fails
    # @example
    #   assistants.hand_back_escalation(thread_id:, assistant_id:, escalation_id: escalation.id,
    #                                   reviewer_id: "jane@example.com",
    #                                   note: "Moved the visit to Friday at 9 by phone.")
    def hand_back_escalation(thread_id:, assistant_id:, escalation_id:, reviewer_id:, note: nil, messages: [], # rubocop:disable Metrics/ParameterLists
                             reply: true, context: {}, reviewed_at: nil)
      decision = { type: "hand_back", note:, messages: Array(messages), reply:, context: }.compact
      resolve_escalation(thread_id:, assistant_id:, escalation_id:, reviewer_id:, reviewed_at:, decision:)
    end

    # Closes an escalated conversation for good: the thread refuses every run after it.
    #
    # @param thread_id [String]
    # @param assistant_id [String] the assistant whose thread it is
    # @param escalation_id [String] the open escalation's id ({Escalation#id})
    # @param reviewer_id [String] who closed it, as the host identifies them
    # @param reviewed_at [Time, String, nil] when they closed it. Defaults to now.
    # @return [Escalation] the closed escalation
    # @raise [ArgumentError] without an `escalation_id` or `reviewer_id`
    # @raise [EscalationNotOpenError] when the thread has no open escalation `escalation_id`
    # @raise [EscalationResolutionError] when Assistants refuses the close
    def close_escalation(thread_id:, assistant_id:, escalation_id:, reviewer_id:, reviewed_at: nil)
      resolve_escalation(thread_id:, assistant_id:, escalation_id:, reviewer_id:, reviewed_at:,
                         decision: { type: "close" })
    end

  private

    def resolve_escalation(thread_id:, assistant_id:, escalation_id:, reviewer_id:, reviewed_at:, decision:)
      raise ArgumentError, "escalation_id is required" if escalation_id.blank?
      raise ArgumentError, "reviewer_id is required" if reviewer_id.blank?

      body = { assistant_id:, escalation_id:, decision:, **reviewer_stamp(reviewer_id, reviewed_at) }
      response = post(path: "/threads/#{thread_id}/escalation", body:)
      refused!(response, EscalationNotOpenError, ESCALATION_NOT_OPEN)
      resolution = parse!(response, EscalationResolutionError)
      raise_run_error!(resolution, RunError)

      resolution_result(resolution)
    end

    # Raises `error`, carrying the escalation the refusal names, when `response` is a `409` for
    # `code`.
    def refused!(response, error, code)
      details = refusal(response, code)
      raise error.new(response.body, escalation: Escalation.from(details["escalation"])) if details
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

    # The escalation a run's failure names, with only its `id` and `status`, or nil when the run
    # failed for another reason.
    def failure_escalation(detail)
      match = detail.to_s.match(THREAD_ESCALATED_FAILURE)
      match && Escalation.new("id" => match[1], "status" => match[2])
    end

    # A resolution answers with the reply run's output, as `/runs/wait` does, or with only the
    # stamp's summary when no reply run started.
    def resolution_result(resolution)
      return Escalation.from(resolution["escalation"]) if resolution.keys == ["escalation"]

      RunResult.new(resolution)
    end
  end
end
