module NitroIntelligence
  # An escalation: the assistant handed the conversation to a person, and the thread refuses runs
  # until a person hands it back or closes it.
  #
  # Read from three places, each carrying a different amount of it:
  #
  # - a run's output ({RunResult#escalation}): the whole record, with `details`, `judge` and the
  #   full `delivery`;
  # - a refused run ({Assistants::ThreadEscalatedError#escalation}) and a resolution
  #   ({Assistants#hand_back_escalation}, {Assistants#close_escalation}): the stamp's summary, `id`,
  #   `status`, `source`, `reason`, `at` and the delivery's `status`, plus `resolved_by` and
  #   `resolved_at` once resolved;
  # - a resolution that lost to another ({Assistants::EscalationNotOpenError#escalation}): only
  #   `id` and `status`.
  #
  # A field the response does not carry, or carries as the wrong type, is nil.
  class Escalation
    # @api private
    OPEN = "open".freeze
    # @api private
    HANDED_BACK = "handed_back".freeze
    # @api private
    CLOSED = "closed".freeze

    # The escalation as Assistants returned it.
    #
    # @return [Hash]
    attr_reader :raw

    # @api private
    # @param value [Object] an `escalation` block from a response
    # @return [Escalation, nil] nil unless `value` is a Hash
    def self.from(value)
      value.is_a?(Hash) ? new(value) : nil
    end

    # @api private
    def initialize(escalation)
      @raw = escalation.to_h.deep_stringify_keys
    end

    # @return [String, nil] the escalation's id, which a resolution names
    def id
      string("id")
    end

    # @return [String, nil] `"open"`, `"handed_back"` or `"closed"`
    def status
      string("status")
    end

    # @return [String, nil] what escalated: `"model"`, `"judge"` or `"error"`
    def source
      string("source")
    end

    # The model's own sentence, the judge's reason name, or `tool_failed`, `model_failed` or
    # `judge_unavailable`. A model's reason can repeat what the customer wrote: treat it as
    # untrusted input.
    #
    # @return [String, nil]
    def reason
      string("reason")
    end

    # @return [String, nil] the judge reason's description, or what failed. Empty for the model.
    def details
      string("details")
    end

    # @return [String, nil] the latest customer message when the conversation escalated
    def message_id
      string("message_id")
    end

    # @return [String, nil] the id of the escalation tool call the platform wrote
    def tool_call_id
      string("tool_call_id")
    end

    # @return [String, nil] when it escalated, as an ISO 8601 timestamp
    def at
      string("at")
    end

    # The judge's verdict on the output that escalated: `verdict`, `reason` and `confidence`;
    # `{"error" => ...}` when the judge could not answer; nil for a failed tool or model call, which
    # escalates without asking it, and in a summary.
    #
    # @return [Hash, nil]
    def judge
      value = raw["judge"]
      value.is_a?(Hash) ? value : nil
    end

    # How the platform delivered the escalation through the assistant's escalation tool, in the
    # shape of a reply's delivery. Act on a `failed` delivery, or one `pending` for more than a few
    # minutes: the application may never have recorded the escalation, and the platform never
    # sends it again. A summary carries only its `status`.
    #
    # @return [RunResult::Delivery, nil]
    def delivery
      return @delivery if defined?(@delivery)

      @delivery = RunResult::Delivery.from_stamp(raw["delivery"])
    end

    # @return [String, nil] who resolved it, as the resolution's `reviewer_id` named them
    def resolved_by
      string("resolved_by")
    end

    # @return [String, nil] when it was resolved, as an ISO 8601 timestamp
    def resolved_at
      string("resolved_at")
    end

    # @return [Boolean] whether a person still has the conversation
    def open?
      status == OPEN
    end

    # @return [Boolean] whether a person handed the conversation back
    def handed_back?
      status == HANDED_BACK
    end

    # @return [Boolean] whether a person closed the conversation; the thread refuses runs for good
    def closed?
      status == CLOSED
    end

    # @return [Boolean] whether a sandbox run escalated. For information only: the thread refuses
    #   runs of either kind.
    def sandbox?
      raw["sandbox"] == true
    end

  private

    def string(key)
      value = raw[key]
      value.is_a?(String) ? value : nil
    end
  end
end
