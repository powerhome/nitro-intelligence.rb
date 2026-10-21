require "active_support/core_ext/hash/indifferent_access"
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

    # The draft reply a reviewer is asked to approve, edit, reject or replace.
    Reply = Struct.new(:content, :allowed_decisions, :description, :interrupt_id, keyword_init: true)

    # A settled reply the delivery tool kept failing to send.
    Delivery = Struct.new(:content, :message_id, :error, :attempts, :allowed_decisions, :description,
                          :interrupt_id, keyword_init: true)

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
        allowed_decisions:,
        description: action_requests.first["description"],
        interrupt_id:
      )
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
        { "type" => "approve" }
      when "edit"
        content = required_text!(review, :content, "edit")
        { "type" => "edit", "edited_action" => { "name" => action_name, "args" => { "content" => content } } }
      when "reject"
        message = optional_text!(review, :message)
        message.nil? ? { "type" => "reject" } : { "type" => "reject", "message" => message }
      when "respond"
        { "type" => "respond", "message" => required_text!(review, :message, "respond") }
      else
        # Allowed by the interrupt but not a decision this client knows how to send. Refused rather
        # than guessed at, for the reason ToolCallReviewInterrupt gives.
        raise_error!("Unsupported review action `#{action}` for the #{kind}")
      end
    end

    def required_text!(review, field, action)
      value = review[field]
      unless value.is_a?(String) && value.present?
        raise_error!("A `#{action}` review of the #{kind} must include a non-empty `#{field}`")
      end

      value
    end

    def optional_text!(review, field)
      value = review[field]
      raise_error!("`#{field}` for the #{kind} review must be a string") unless value.nil? || value.is_a?(String)

      value
    end

    def raise_error!(message)
      raise Assistants::ThreadResumptionError, message
    end
  end
end
