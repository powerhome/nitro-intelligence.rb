require "active_support/core_ext/hash/indifferent_access"
require "nitro_intelligence/review_decision"
require "nitro_intelligence/tool_call_review_interrupt"
require "nitro_intelligence/tool_call_review_validator"

module NitroIntelligence
  # What a paused run is waiting on: the interrupt the thread is holding, and the decisions that
  # answer it.
  #
  # Assistants pauses for two kinds of review, never mixed in one interrupt:
  #
  # - tool calls, held by LangChain's `HumanInTheLoopMiddleware`, one action per call;
  # - the run's final reply, a single action named `__reply__` whose `args` carry the draft's
  #   `content`.
  #
  # A turn with tool calls only ever pauses on its tool calls, and the reply is the run's final
  # message, so `#tool_calls` and `#reply` are never both present.
  #
  # Built from a thread state (`GET /threads/{id}/state`, which reports `interrupts`) or from the
  # response of a paused `/runs/wait` (which reports `__interrupt__`); both carry the messages the
  # tool calls are matched back onto.
  class PendingReview
    REPLY_ACTION = "__reply__".freeze

    # What a reviewer may do with a reply. LangChain's `respond` supplies a tool's result, which a
    # reply does not have, so it is never offered for one, whatever the interrupt lists.
    REPLY_DECISIONS = %w[approve edit reject].freeze

    KIND_NAMES = { tool_calls: "tool calls", reply: "a reply" }.freeze

    # The draft reply a reviewer is asked to approve, edit or reject.
    Reply = Struct.new(:content, :allowed_decisions, :description, :interrupt_id, keyword_init: true)

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

    # `:tool_calls` or `:reply`.
    def kind
      action_name == REPLY_ACTION ? :reply : :tool_calls
    end

    def tool_calls?
      kind == :tool_calls
    end

    def reply?
      kind == :reply
    end

    # The tool calls the interrupt is holding, as `Assistants#tool_calls_under_review` reports them.
    # Empty when the pause is on a reply.
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
    # and paused again does -- a turn's tool calls decided, then the run's reply held. What tells
    # them apart is who wrote the thread's latest checkpoint: Assistants records each run's id in
    # the metadata of the checkpoints it writes, and a resume that decided nothing writes none, so
    # the pause it reports still sits on a checkpoint an earlier run wrote.
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

    # The `command.resume` decisions for a review of this pause, validated against what the
    # interrupt allows before anything is built, raising `Assistants::ThreadResumptionError`.
    #
    # For a reply, `reviews` is a single review hash. For tool calls, it is either a hash of reviews
    # keyed by tool call id, as `Assistants#review_tool_calls` has always taken them, or a list of
    # reviews that each carry their tool call's `id`.
    def decisions(reviews)
      return [reply_decision(reviews)] if reply?

      reviews = tool_call_reviews(reviews)
      ToolCallReviewValidator.new.validate!(tool_calls: reviews, tool_calls_under_review: tool_calls)
      tool_call_interrupt.decisions(reviews)
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

    def action_requests
      Array(interrupt_value["action_requests"])
    end

    def action_name
      action_requests.first&.dig("name")
    end

    def action_args
      action_requests.first["args"] || {}
    end

    def allowed_decisions
      review_config = Array(interrupt_value["review_configs"]).find do |config|
        config["action_name"] == action_name
      end

      Array(review_config&.dig("allowed_decisions")).map(&:to_s) & REPLY_DECISIONS
    end

    def tool_call_reviews(reviews)
      return reviews unless reviews.is_a?(Array)

      reviews.each_with_object({}) do |review, by_id|
        unless review.is_a?(Hash) && review.with_indifferent_access[:id].present?
          raise_error!("Each tool call review in a list must be a hash with the tool call's `id`")
        end

        review = review.with_indifferent_access
        id = review[:id].to_s
        raise_error!("Tool call `#{id}` is reviewed more than once") if by_id.key?(id)

        by_id[id] = review.except(:id)
      end
    end

    # A reply is a single action, so it is reviewed with a single hash.
    def reply_decision(review)
      raise_error!("The reply review must be a hash") unless review.is_a?(Hash)

      review = review.with_indifferent_access
      action = review[:action].to_s

      unless allowed_decisions.include?(action)
        raise_error!("Invalid review action `#{action}` for the reply; allowed: #{allowed_decisions.join(', ')}")
      end

      case action
      when "approve" then ReviewDecision.approve
      when "edit"
        ReviewDecision.edit(REPLY_ACTION, { "content" => text!(review, :content, action:, required: true) })
      when "reject" then ReviewDecision.reject(text!(review, :message, action:, required: false))
      end
    end

    # A required field must be non-blank text; an optional one may be absent, but not something other
    # than a String.
    def text!(review, field, action:, required:)
      value = review[field]
      case ReviewDecision.message_problem(value, required:)
      when :missing then raise_error!("A `#{action}` review of the reply must include a non-empty `#{field}`")
      when :not_string then raise_error!("`#{field}` for the reply review must be a string")
      end

      value
    end

    def raise_error!(message)
      raise Assistants::ThreadResumptionError, message
    end
  end
end
