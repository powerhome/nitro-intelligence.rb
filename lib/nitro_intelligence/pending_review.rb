require "active_support/core_ext/hash/indifferent_access"
require "nitro_intelligence/tool_call_review_interrupt"
require "nitro_intelligence/tool_call_review_validator"

module NitroIntelligence
  # What a paused run is waiting on: the interrupt the thread is holding, and the decisions that
  # answer it.
  #
  # Tool calls are held by LangChain's `HumanInTheLoopMiddleware`, one action per call.
  #
  # Built from a thread state (`GET /threads/{id}/state`, which reports `interrupts`) or from the
  # response of a paused `/runs/wait` (which reports `__interrupt__`); both carry the messages the
  # tool calls are matched back onto.
  class PendingReview
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

    # The tool calls the interrupt is holding, as `Assistants#tool_calls_under_review` reports them.
    def tool_calls
      tool_call_interrupt.tool_calls
    end

    # The `command.resume` decisions for a review of this pause: tool call reviews keyed by tool call
    # id, as `Assistants#review_tool_calls` takes them. Every review is validated against what the
    # interrupt allows, raising `Assistants::ThreadResumptionError`, before anything is built.
    def decisions(reviews)
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
  end
end
