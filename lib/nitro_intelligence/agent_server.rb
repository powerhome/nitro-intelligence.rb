require "nitro_intelligence/tool_call_review_validator"

module NitroIntelligence
  class AgentServer
    class ConfigurationError < StandardError; end
    class ThreadInitializationError < StandardError; end
    class RunError < StandardError; end
    class ThreadResumptionError < StandardError; end

    attr_reader :base_url, :user_id

    def initialize(base_url:, api_key:, user_id: "default-user")
      raise ConfigurationError, "base_url is required" if base_url.blank?
      raise ConfigurationError, "api_key is required" if api_key.blank?
      raise ConfigurationError, "user_id is required" if user_id.blank?

      @base_url = base_url
      @api_key = api_key
      @user_id = user_id
      @tool_call_review_validator = ToolCallReviewValidator.new
    end

    def await_run(thread_id:, assistant_id:, messages:, context: {})
      raise RunError, "messages cannot be empty" if messages.blank?

      initial_state = messages[0..-2]
      last_message = messages.last

      initialize_thread_if_needed(thread_id:, initial_state:)
      trigger_run(thread_id:, assistant_id:, context:, last_message:)
    end

    def tool_calls_pending_review(thread_id:)
      thread_state = get_thread_state(thread_id:)
      messages = thread_messages(thread_state)
      reviewed_tool_call_ids = tool_messages(messages).map { |message| message["tool_call_id"] }

      messages.each_with_index.flat_map do |message, index|
        next [] unless message["type"] == "ai"

        pending_tool_calls(message, reviewed_tool_call_ids).map do |tool_call|
          {
            "previous_message_id" => index.zero? ? nil : messages[index - 1]&.dig("id"),
            "id" => tool_call["id"],
            "name" => tool_call["name"],
            "args" => tool_call["args"] || {},
          }
        end
      end
    end

    def review_tool_calls(thread_id:, assistant_id:, reviewer_id:, tool_calls:, reviewed_at: DateTime.current.iso8601)
      resume = { reviewer_id:, reviewed_at:, tool_calls: }.with_indifferent_access
      thread = get_thread(thread_id:)
      raise ThreadResumptionError, "Thread #{thread_id} is not in the interrupted state" unless interrupted?(thread)

      thread_state = get_thread_state(thread_id:)

      @tool_call_review_validator.validate!(
        thread_state:,
        tool_calls: resume[:tool_calls],
        pending_tool_calls: tool_calls_pending_review(thread_id:)
      )

      resume_run(
        thread_id:,
        assistant_id:,
        resume:,
        context: interrupt_context(thread_state)
      )

      nil
    end

  private

    def initialize_thread_if_needed(thread_id:, initial_state:)
      thread_response = post(
        path: "/threads",
        body: {
          threadId: thread_id.to_s,
          ifExists: "do_nothing",
          initial_state: { messages: initial_state },
          user_id:,
        }
      )

      raise ThreadInitializationError, thread_response.body if thread_response.code != 200

      thread_response
    end

    def get_thread_state(thread_id:)
      state_response = get(path: "/threads/#{thread_id}/state")

      raise ThreadResumptionError, state_response.body if state_response.code != 200

      state_response
    end

    def get_thread(thread_id:)
      thread_response = get(path: "/threads/#{thread_id}")

      raise ThreadResumptionError, thread_response.body if thread_response.code != 200

      thread_response
    end

    def trigger_run(thread_id:, assistant_id:, last_message:, context: {})
      run_response = post(
        path: "/threads/#{thread_id}/runs/wait",
        body: {
          assistant_id:,
          context:,
          input: {
            messages: [last_message],
          },
        }
      )

      raise RunError, run_response.body if run_response.code != 200

      Array(run_response["messages"]).last&.dig("content")
    end

    def resume_run(thread_id:, assistant_id:, resume:, context:)
      run_response = post(
        path: "/threads/#{thread_id}/runs/wait",
        body: {
          assistant_id:,
          command: {
            resume:,
          },
          context:,
        }
      )

      raise ThreadResumptionError, run_response.body if run_response.code != 200

      run_response
    end

    def interrupted?(thread)
      thread["status"] == "interrupted"
    end

    def interrupt_context(thread_state)
      thread_state.dig("interrupts", 0, "value", "context") || {}
    end

    def thread_messages(thread_state)
      Array(thread_state.dig("values", "messages"))
    end

    def tool_messages(messages)
      messages.select { |message| message["type"] == "tool" }
    end

    def pending_tool_calls(message, reviewed_tool_call_ids)
      Array(message["tool_calls"]).reject do |tool_call|
        reviewed_tool_call_ids.include?(tool_call["id"])
      end
    end

    def get(path:)
      HTTParty.get(
        "#{base_url}#{path}",
        headers: request_headers
      )
    end

    def post(path:, body:)
      HTTParty.post(
        "#{base_url}#{path}",
        headers: request_headers,
        body: body.to_json
      )
    end

    def request_headers
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@api_key}",
      }
    end
  end
end
