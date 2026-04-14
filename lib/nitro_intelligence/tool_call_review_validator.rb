require "active_support/core_ext/hash/indifferent_access"

module NitroIntelligence
  class ToolCallReviewValidator
    def validate!(thread_state:, tool_calls:, pending_tool_calls:)
      tool_calls = normalize_tool_calls(tool_calls)
      pending_tool_calls_by_id = Array(pending_tool_calls).index_by { |tool_call| tool_call["id"] }
      review_actions = Array(thread_state.dig("interrupts", 0, "value", "review_actions"))

      tool_calls.each do |tool_call_id, review|
        pending_tool_call = pending_tool_calls_by_id[tool_call_id]&.with_indifferent_access
        raise_error!("Unknown tool call ids: #{tool_call_id}") unless pending_tool_call

        review = normalize_review(tool_call_id, review)
        review_action = review[:action].to_s

        unless review_actions.include?(review_action)
          raise_error!("Invalid review action `#{review_action}` for tool call #{tool_call_id}")
        end

        validate_edited_args!(tool_call_id:, review:, pending_tool_call:) if review_action == "edit"
      end

      validate_completeness!(
        submitted_tool_call_ids: tool_calls.keys,
        pending_tool_calls:
      )
    end

  private

    def normalize_tool_calls(tool_calls)
      raise_error!("tool_calls must be a hash") unless tool_calls.is_a?(Hash)

      tool_calls.with_indifferent_access
    end

    def normalize_review(tool_call_id, review)
      raise_error!("Review for tool call #{tool_call_id} must be a hash") unless review.is_a?(Hash)

      review.with_indifferent_access
    end

    def validate_edited_args!(tool_call_id:, review:, pending_tool_call:)
      provided_args = review[:args]
      raise_error!("Edited args for tool call #{tool_call_id} must be a hash") unless provided_args.is_a?(Hash)

      valid_arg_names = pending_tool_call.fetch(:args, {}).keys.map(&:to_s)
      invalid_arg_names = provided_args.keys.map(&:to_s) - valid_arg_names
      return if invalid_arg_names.empty?

      raise_error!("Invalid edited args for tool call #{tool_call_id}: #{invalid_arg_names.join(', ')}")
    end

    def validate_completeness!(submitted_tool_call_ids:, pending_tool_calls:)
      missing_tool_call_ids = Array(pending_tool_calls).filter_map do |tool_call|
        tool_call_id = tool_call["id"].to_s
        tool_call_id unless submitted_tool_call_ids.include?(tool_call_id)
      end
      return if missing_tool_call_ids.empty?

      raise_error!("Missing reviews for tool calls: #{missing_tool_call_ids.join(', ')}")
    end

    def raise_error!(message)
      raise NitroIntelligence::AgentServer::ThreadResumptionError, message
    end
  end
end
