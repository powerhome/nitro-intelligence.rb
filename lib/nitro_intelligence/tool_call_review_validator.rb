require "active_support/core_ext/hash/indifferent_access"

module NitroIntelligence
  class ToolCallReviewValidator
    def validate!(tool_calls:, tool_calls_under_review:)
      tool_calls = normalize_tool_calls(tool_calls)
      tool_calls_under_review_by_id = Array(tool_calls_under_review).index_by { |tool_call| tool_call["id"] }

      tool_calls.each do |tool_call_id, review|
        tool_call_under_review = tool_calls_under_review_by_id[tool_call_id]&.with_indifferent_access
        raise_error!("Unknown tool call ids: #{tool_call_id}") unless tool_call_under_review

        review = normalize_review(tool_call_id, review)
        review_action = review[:action].to_s

        unless Array(tool_call_under_review[:allowed_decisions]).include?(review_action)
          raise_error!("Invalid review action `#{review_action}` for tool call #{tool_call_id}")
        end

        validate_review_details!(tool_call_id:, review:, review_action:, tool_call_under_review:)
      end

      validate_completeness!(
        submitted_tool_call_ids: tool_calls.keys,
        tool_calls_under_review:
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

    def validate_review_details!(tool_call_id:, review:, review_action:, tool_call_under_review:)
      case review_action
      when "edit"
        validate_edited_args!(tool_call_id:, review:, tool_call_under_review:)
      when "reject"
        # The middleware falls back to its own wording when a rejection carries no reason.
        validate_message!(tool_call_id:, review:, required: false)
      when "respond"
        # The message is returned to the model as the tool's result, so there is nothing to send
        # without it.
        validate_message!(tool_call_id:, review:, required: true)
      end
    end

    def validate_edited_args!(tool_call_id:, review:, tool_call_under_review:)
      provided_args = review[:args]
      raise_error!("Edited args for tool call #{tool_call_id} must be a hash") unless provided_args.is_a?(Hash)

      valid_arg_names = tool_call_under_review.fetch(:args, {}).keys.map(&:to_s)
      invalid_arg_names = provided_args.keys.map(&:to_s) - valid_arg_names
      return if invalid_arg_names.empty?

      raise_error!("Invalid edited args for tool call #{tool_call_id}: #{invalid_arg_names.join(', ')}")
    end

    def validate_message!(tool_call_id:, review:, required:)
      message = review[:message]

      if message.nil?
        raise_error!("Review for tool call #{tool_call_id} must include a message") if required
        return
      end

      raise_error!("Message for tool call #{tool_call_id} must be a string") unless message.is_a?(String)
      raise_error!("Review for tool call #{tool_call_id} must include a message") if required && message.blank?
    end

    def validate_completeness!(submitted_tool_call_ids:, tool_calls_under_review:)
      missing_tool_call_ids = Array(tool_calls_under_review).filter_map do |tool_call|
        tool_call_id = tool_call["id"].to_s
        tool_call_id unless submitted_tool_call_ids.include?(tool_call_id)
      end
      return if missing_tool_call_ids.empty?

      raise_error!("Missing reviews for tool calls: #{missing_tool_call_ids.join(', ')}")
    end

    def raise_error!(message)
      raise NitroIntelligence::Assistants::ThreadResumptionError, message
    end
  end
end
