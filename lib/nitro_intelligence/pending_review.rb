require "active_support/core_ext/hash/indifferent_access"
require "nitro_intelligence/review_decision"
require "nitro_intelligence/tool_call_review_interrupt"
require "nitro_intelligence/tool_call_review_validator"

module NitroIntelligence
  # What a paused run is waiting on: the interrupt the thread is holding, and the decisions that
  # answer it.
  #
  # Assistants pauses for three kinds of review, never mixed in one interrupt:
  #
  # - tool calls, held by LangChain's `HumanInTheLoopMiddleware`, one action per call;
  # - the reply, a single action named `__reply__` whose `args` carry the draft's `content`;
  # - a failed delivery, a single action named `__delivery__` whose `args` carry the reply's
  #   `content`, its `message_id`, the delivery tool's `error` and the number of `attempts`.
  #
  # A model turn with both text and a held tool call pauses twice: on its tool calls first, then,
  # once they are decided, on its text. So `#tool_calls` and `#reply` are never both present.
  #
  # Built from a thread state (`GET /threads/{id}/state`, which reports `interrupts`) or from the
  # response of a paused `/runs/wait` (which reports `__interrupt__`); both carry the messages the
  # tool calls are matched back onto.
  class PendingReview
    REPLY_ACTION = "__reply__".freeze
    DELIVERY_ACTION = "__delivery__".freeze

    # A failed delivery is not reviewed by policy but recovered from, so its decisions are fixed
    # rather than configured: deliver the same text again, or give up. What the reply says was
    # settled before the first attempt, so nothing here changes it: there is no `edit` or `respond`.
    # `retry` is the pause's own decision rather than LangChain's `approve`, since nothing is
    # approved by it.
    DELIVERY_DECISIONS = %w[retry reject].freeze

    # The draft reply a reviewer is asked to approve, edit, reject or replace.
    Reply = Struct.new(:content, :allowed_decisions, :description, :interrupt_id, keyword_init: true)

    # A settled reply the delivery tool kept failing to send. `failed_at` and `retries` come from the
    # reply's own `response_metadata.delivery` stamp, so that a retry job can decide when to give up:
    # `failed_at` is when the latest round failed, nil when the stamp does not say, and `retries` the
    # manual retries so far, oldest first, empty until someone has retried it.
    Delivery = Struct.new(:content, :message_id, :error, :attempts, :failed_at, :retries, :allowed_decisions,
                          :description, :interrupt_id, keyword_init: true)

    # One manual retry of a failed delivery: who retried it and when, and the failure it answered --
    # that round's `error` and `attempts`. A field the stamp does not carry, or carries as something
    # else than a string (an integer, for `attempts`), is nil.
    DeliveryRetry = Struct.new(:reviewer_id, :reviewed_at, :error, :attempts, keyword_init: true)

    # The pending review in a thread state, or nil when the thread is not paused.
    def self.from_thread_state(thread_state)
      interrupt = Array(thread_state["interrupts"]).first
      interrupt && new(interrupt:, messages: Array(thread_state.dig("values", "messages")))
    end

    # The pending review in a `/runs/wait` response, or nil when the run did not pause.
    def self.from_run(run)
      interrupt = Array(run["__interrupt__"]).first
      interrupt && new(interrupt:, messages: Array(run["messages"]))
    end

    def initialize(interrupt:, messages:)
      @interrupt = interrupt.to_h
      @messages = messages
    end

    # Identifies this pause. A thread that has moved on -- a new message superseded the review, or
    # another reviewer decided it first -- reports a different interrupt, or none.
    def interrupt_id
      @interrupt["id"] || @interrupt["interrupt_id"]
    end

    # `:tool_calls`, `:reply` or `:delivery`.
    def kind
      case action_requests.first&.dig("name")
      when REPLY_ACTION then :reply
      when DELIVERY_ACTION then :delivery
      else :tool_calls
      end
    end

    def tool_calls?
      kind == :tool_calls
    end

    def reply?
      kind == :reply
    end

    def delivery?
      kind == :delivery
    end

    # The tool calls the interrupt is holding, as `Assistants#tool_calls_under_review` reports them.
    # Empty when the pause is on a reply or a delivery.
    def tool_calls
      return [] unless tool_calls?

      tool_call_interrupt.tool_calls
    end

    # The held draft, or nil when the pause is not on a reply.
    def reply
      return nil unless reply?

      @reply ||= Reply.new(
        content: action_args["content"],
        allowed_decisions:,
        description: action_requests.first["description"],
        interrupt_id:
      )
    end

    # The undelivered reply, or nil when the pause is not on a delivery.
    def delivery
      return nil unless delivery?

      @delivery ||= Delivery.new(
        content: action_args["content"],
        message_id: action_args["message_id"],
        error: action_args["error"],
        attempts: action_args["attempts"],
        failed_at: string_or_nil(delivery_stamp["failed_at"]),
        retries: delivery_retries,
        allowed_decisions:,
        description: action_requests.first["description"],
        interrupt_id:
      )
    end

    # The `command.resume` that sends `decisions` to this pause, keyed by its interrupt. LangGraph
    # applies a keyed resume to that interrupt only: keyed by one that is no longer pending -- the
    # thread moved on between reading this pause and resuming it -- it decides nothing, and the
    # thread stays paused on the newer interrupt. An interrupt reported without an id can only be
    # resumed unkeyed.
    def resume(decisions)
      interrupt_id.blank? ? { decisions: } : { interrupt_id => { decisions: } }
    end

    # Whether `run`, the response to a keyed resume of this pause, decided nothing because the
    # interrupt was gone by the time the resume arrived. `run_id` is the run Assistants created for
    # the resume, and the block reads the thread's state, only when it is needed.
    #
    # Such a resume comes back paused on the newer interrupt, exactly as a resume that was applied
    # and paused again does -- a turn's reply after its tool calls, a delivery that fails again.
    # What tells them apart is who wrote the thread's latest checkpoint: Assistants records each
    # run's id in the metadata of the checkpoints it writes, and a resume that decided nothing writes
    # none, so the pause it reports still sits on a checkpoint an earlier run wrote.
    #
    # Best-effort, and only ever true on that evidence: without the run's id, the checkpoint's, or a
    # state still on the reported pause (a new message may already have moved it on), or when the
    # state cannot be read, it is false and the result stands as returned. That a stale decision is
    # never applied is guaranteed by the keyed resume, not by this.
    def unapplied_resume?(run:, run_id:)
      paused_on = self.class.from_run(run)&.interrupt_id
      return false if interrupt_id.blank? || run_id.blank? || paused_on.blank? || paused_on == interrupt_id

      state = yield
      writer = state.dig("metadata", "run_id")
      self.class.from_thread_state(state)&.interrupt_id == paused_on && writer.present? && writer != run_id
    rescue
      false
    end

    # The `command.resume` decisions for a review of this pause. `reviews` takes the shape of the
    # pause: tool call reviews keyed by tool call id, as `Assistants#review_tool_calls` takes them,
    # or a single review hash for a reply or a delivery. Every review is validated against what the
    # interrupt allows, raising `Assistants::ThreadResumptionError`, before anything is built.
    def decisions(reviews)
      if tool_calls?
        ToolCallReviewValidator.new.validate!(tool_calls: reviews, tool_calls_under_review: tool_calls)
        tool_call_interrupt.decisions(reviews)
      else
        [text_decision(reviews)]
      end
    end

  private

    def tool_call_interrupt
      @tool_call_interrupt ||= ToolCallReviewInterrupt.new(
        "interrupts" => [@interrupt],
        "values" => { "messages" => @messages }
      )
    end

    def interrupt_value
      @interrupt["value"] || {}
    end

    # The held reply's `response_metadata.delivery`: the AI message the pause names by `message_id`,
    # among the messages this was built with. Empty when it is not among them.
    def delivery_stamp
      @delivery_stamp ||= begin
        message_id = action_args["message_id"]
        message = @messages.find do |candidate|
          candidate.is_a?(Hash) && candidate["id"] == message_id && candidate.fetch("type", "ai") == "ai"
        end
        stamp = message_id.present? ? message&.dig("response_metadata", "delivery") : nil
        stamp.is_a?(Hash) ? stamp : {}
      end
    end

    # A malformed entry -- anything but an object -- is skipped rather than raised: the history is
    # the platform's audit record, and a retry job reading it should not fail on one bad entry.
    def delivery_retries
      retries = delivery_stamp["retries"]
      return [] unless retries.is_a?(Array)

      retries.grep(Hash).map do |entry|
        DeliveryRetry.new(
          reviewer_id: string_or_nil(entry["reviewer_id"]),
          reviewed_at: string_or_nil(entry["reviewed_at"]),
          error: string_or_nil(entry["error"]),
          attempts: entry["attempts"].is_a?(Integer) ? entry["attempts"] : nil
        )
      end
    end

    def string_or_nil(value)
      value.is_a?(String) ? value : nil
    end

    def action_requests
      Array(interrupt_value["action_requests"])
    end

    def action_args
      action_requests.first["args"] || {}
    end

    def action_name
      action_requests.first["name"]
    end

    def allowed_decisions
      return DELIVERY_DECISIONS if delivery?

      review_config = Array(interrupt_value["review_configs"]).find do |config|
        config["action_name"] == action_name
      end

      Array(review_config&.dig("allowed_decisions")).map(&:to_s)
    end

    # A reply and a delivery are a single action each, so they are reviewed with a single hash.
    def text_decision(review)
      raise_error!("The #{kind} review must be a hash") unless review.is_a?(Hash)

      review = review.with_indifferent_access
      action = review[:action].to_s

      unless allowed_decisions.include?(action)
        raise_error!("Invalid review action `#{action}` for the #{kind}; " \
                     "allowed: #{allowed_decisions.join(', ')}")
      end

      case action
      when "approve"
        ReviewDecision.approve
      when "retry"
        # A delivery's own decision; a reply config that listed it would mean nothing to Assistants.
        raise_error!("Unsupported review action `retry` for the #{kind}") unless delivery?

        { "type" => "retry" }
      when "edit"
        ReviewDecision.edit(action_name, { "content" => text!(review, :content, action:, required: true) })
      when "reject"
        ReviewDecision.reject(text!(review, :message, action:, required: false))
      when "respond"
        ReviewDecision.respond(text!(review, :message, action:, required: true))
      else
        # Allowed by the interrupt but not a decision this client knows how to send. Refused rather
        # than guessed at, for the reason ToolCallReviewInterrupt gives.
        raise_error!("Unsupported review action `#{action}` for the #{kind}")
      end
    end

    # A required field given as anything but non-blank text is reported as missing; an optional one
    # may be absent, but not something other than a String.
    def text!(review, field, action:, required:)
      value = review[field]
      return value unless ReviewDecision.message_problem(value, required:)

      raise_error!("A `#{action}` review of the #{kind} must include a non-empty `#{field}`") if required

      raise_error!("`#{field}` for the #{kind} review must be a string")
    end

    def raise_error!(message)
      raise Assistants::ThreadResumptionError, message
    end
  end
end
