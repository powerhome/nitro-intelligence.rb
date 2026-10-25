module NitroIntelligence
  # The `command.resume` decisions a review sends, and the check on the `message` a decision
  # carries, shared by tool call reviews and reply reviews. Each caller keeps its own
  # error wording, so this reports what is wrong rather than raising.
  module ReviewDecision
  module_function

    def approve
      { "type" => "approve" }
    end

    def edit(name, args)
      { "type" => "edit", "edited_action" => { "name" => name, "args" => args } }
    end

    # The middleware falls back to its own wording when a rejection carries no reason.
    def reject(message)
      message.nil? ? { "type" => "reject" } : { "type" => "reject", "message" => message }
    end

    def respond(message)
      { "type" => "respond", "message" => message }
    end

    # What is wrong with a decision's `message`, or nil: `:missing` when a required one is absent
    # or blank, `:not_string` when one is given as anything but a String.
    def message_problem(message, required:)
      return (:missing if required) if message.nil?
      return :not_string unless message.is_a?(String)

      :missing if required && message.blank?
    end
  end
end
