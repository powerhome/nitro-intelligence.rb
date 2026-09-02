require "active_support/core_ext/hash/indifferent_access"

module NitroIntelligence
  # The tool calls one interrupt is holding, and the resume payload that answers them.
  #
  # LangChain's `HumanInTheLoopMiddleware` publishes `action_requests` -- a tool name, its arguments
  # and a description -- alongside a `review_configs` entry per tool naming the decisions a reviewer
  # may take. It resumes with `decisions`, one per action request, matched to them by position.
  #
  # Action requests carry no tool call id, and ids are what a review interface works in, so each is
  # matched back onto the tool calls of the thread's last AI message -- the ones the middleware built
  # them from -- to recover the id. The order of `#tool_calls` is the order `decisions` must be in.
  class ToolCallReviewInterrupt
    def initialize(thread_state)
      @thread_state = thread_state
    end

    def tool_calls
      @tool_calls ||= build_tool_calls
    end

    # The `command.resume` payload for the reviews, ordered to match the action requests. Callers
    # key their reviews by tool call id; the platform wants a positional list.
    def decisions(reviews)
      reviews = reviews.with_indifferent_access

      tool_calls.map { |tool_call| decision_for(tool_call, reviews[tool_call["id"]]) }
    end

  private

    def build_tool_calls
      unmatched = last_ai_tool_calls.dup

      action_requests.map do |action_request|
        tool_call = take_matching_tool_call(unmatched, action_request)

        {
          "previous_message_id" => previous_message_id,
          "id" => tool_call["id"],
          "name" => tool_call["name"],
          "args" => tool_call["args"] || {},
          "allowed_decisions" => allowed_decisions_by_tool_name.fetch(action_request["name"], []),
        }
      end
    end

    # Arguments distinguish two calls to the same tool, and a name-only match covers a platform that
    # reformats them on the way into the interrupt.
    def take_matching_tool_call(unmatched, action_request)
      name = action_request["name"]
      index = unmatched.index { |tool_call| tool_call["name"] == name && tool_call["args"] == action_request["args"] }
      index ||= unmatched.index { |tool_call| tool_call["name"] == name }

      unless index
        raise Assistants::ThreadResumptionError,
              "No tool call on the thread matches the interrupt's action request for `#{name}`"
      end

      unmatched.delete_at(index)
    end

    def decision_for(tool_call, review)
      review = (review || {}).with_indifferent_access

      case review[:action].to_s
      when "edit"
        { "type" => "edit", "edited_action" => edited_action(tool_call, review) }
      when "reject"
        review[:message].nil? ? { "type" => "reject" } : { "type" => "reject", "message" => review[:message] }
      when "respond"
        { "type" => "respond", "message" => review[:message] }
      else
        { "type" => "approve" }
      end
    end

    # Edited arguments are merged over the call the model made, so a reviewer changing one of them
    # does not have to restate the rest -- and cannot drop one by omitting it.
    def edited_action(tool_call, review)
      {
        "name" => tool_call["name"],
        "args" => tool_call["args"].merge(review[:args] || {}),
      }
    end

    def interrupt_value
      @interrupt_value ||= @thread_state.dig("interrupts", 0, "value") || {}
    end

    def action_requests
      Array(interrupt_value["action_requests"])
    end

    def allowed_decisions_by_tool_name
      @allowed_decisions_by_tool_name ||= Array(interrupt_value["review_configs"]).to_h do |review_config|
        [review_config["action_name"], Array(review_config["allowed_decisions"]).map(&:to_s)]
      end
    end

    def last_ai_tool_calls
      Array(last_ai_message&.dig("tool_calls"))
    end

    # An interrupt only ever holds the tool calls of the message the model has just produced.
    def last_ai_message_index
      @last_ai_message_index ||= messages.rindex do |message|
        message["type"] == "ai" && Array(message["tool_calls"]).any?
      end
    end

    def last_ai_message
      last_ai_message_index && messages[last_ai_message_index]
    end

    # The message the reviewer needs to read to judge the call, as #tool_calls_pending_review
    # reports it: the one immediately before the tool-call attempt.
    def previous_message_id
      return nil if last_ai_message_index.nil? || last_ai_message_index.zero?

      messages[last_ai_message_index - 1]&.dig("id")
    end

    def messages
      @messages ||= Array(@thread_state.dig("values", "messages"))
    end
  end
end
