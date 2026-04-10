module NitroIntelligence
  class AgentServer
    class ConfigurationError < StandardError; end
    class ThreadInitializationError < StandardError; end
    class RunError < StandardError; end

    attr_reader :base_url, :user_id

    def initialize(base_url:, api_key:, user_id: "default-user")
      raise ConfigurationError, "base_url is required" if base_url.blank?
      raise ConfigurationError, "api_key is required" if api_key.blank?
      raise ConfigurationError, "user_id is required" if user_id.blank?

      @base_url = base_url
      @api_key = api_key
      @user_id = user_id
    end

    def await_run(thread_id:, assistant_id:, messages:, context: {})
      raise RunError, "messages cannot be empty" if messages.blank?

      *initial_state, last_message = messages
      initial_state = [] if messages.size == 1
      last_message = messages.first if messages.size == 1

      initialize_thread_if_needed(thread_id:, initial_state:)
      trigger_run(thread_id:, assistant_id:, context:, last_message:)
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

      run_response["messages"].last["content"]
    end

    def post(path:, body:)
      HTTParty.post(
        "#{base_url}#{path}",
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{@api_key}",
        },
        body: body.to_json
      )
    end
  end
end
