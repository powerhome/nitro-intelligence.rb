require "json"
require "net/http"
require "uri"
require "nitro_intelligence/deprecation"
require "nitro_intelligence/tool_call_review_interrupt"
require "nitro_intelligence/tool_call_review_validator"

module NitroIntelligence
  class Assistants
    class ConfigurationError < StandardError; end
    class ThreadInitializationError < StandardError; end
    class RunError < StandardError; end
    class ThreadResumptionError < StandardError; end
    class ThreadStateError < StandardError; end

    # Assistants answers with a conflict when `ifExists: "raise"` is sent for a thread that already exists.
    THREAD_CONFLICT_CODE = 409

    attr_reader :base_url, :user_id

    def initialize(base_url:, api_key:, user_id: "default-user")
      raise ConfigurationError, "base_url is required" if base_url.blank?
      raise ConfigurationError, "api_key is required" if api_key.blank?
      raise ConfigurationError, "user_id is required" if user_id.blank?

      @base_url = base_url
      @api_key = api_key
      @user_id = user_id
      @tool_call_review_validator = ToolCallReviewValidator.new
      @graph_ids = {}
    end

    def await_run(thread_id:, assistant_id:, messages:, context: {})
      raise RunError, "messages cannot be empty" if messages.blank?

      initial_state = messages[0..-2]
      last_message = messages.last

      initialize_thread_if_needed(thread_id:, assistant_id:, initial_state:)
      trigger_run(thread_id:, assistant_id:, context:, last_message:)
    end

    # The thread's state as Assistants reports it, unformatted. Callers that only want the
    # conversation should reach for #thread_messages instead.
    def thread_state(thread_id:)
      get_thread_state(thread_id:, error: ThreadStateError)
    end

    # The thread's messages as Assistants reports them, unformatted, oldest first. Each message
    # carries its own `type` ("human", "ai", "tool", ...), which callers map to their own roles.
    def thread_messages(thread_id:)
      messages_in(thread_state(thread_id:))
    end

    def tool_calls_pending_review(thread_id:)
      thread_state = get_thread_state(thread_id:)
      messages = messages_in(thread_state)
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

    # The tool calls the thread's interrupt is holding, in the order the platform wants decisions
    # for them, each with the `allowed_decisions` a reviewer may take on it. Empty when the thread
    # is not waiting on a review.
    #
    # A tool the assistant is not configured to interrupt on runs without review, so an AI message
    # can mix calls under review with calls that are only waiting to be executed. This reports the
    # former; #tool_calls_pending_review reports both.
    def tool_calls_under_review(thread_id:)
      ToolCallReviewInterrupt.new(get_thread_state(thread_id:)).tool_calls
    end

    # Resumes an interrupted thread with one review per tool call the interrupt is holding. Each
    # review is keyed by tool call id and names an `action` -- `approve`, `edit`, `reject` or
    # `respond` -- from the decisions the interrupt allows for that tool. `edit` carries `args`,
    # merged over the arguments the model asked for; `respond` carries the `message` returned to the
    # model as the tool's result; `reject` may carry a `message` explaining the refusal.
    #
    # `reviewer_id` and `reviewed_at` are deprecated and ignored: Assistants records neither, and
    # the resume payload it accepts has nowhere to carry them.
    def review_tool_calls(thread_id:, assistant_id:, tool_calls:, context: {}, reviewer_id: nil, reviewed_at: nil)
      warn_about_reviewer_attribution(reviewer_id:, reviewed_at:)

      thread = get_thread(thread_id:)
      raise ThreadResumptionError, "Thread #{thread_id} is not in the interrupted state" unless interrupted?(thread)

      interrupt = ToolCallReviewInterrupt.new(get_thread_state(thread_id:))
      tool_calls_under_review = interrupt.tool_calls

      if tool_calls_under_review.empty?
        raise ThreadResumptionError, "Thread #{thread_id} has no tool calls awaiting review"
      end

      @tool_call_review_validator.validate!(tool_calls:, tool_calls_under_review:)

      resume_run(
        thread_id:,
        assistant_id:,
        resume: { decisions: interrupt.decisions(tool_calls) },
        context:
      )

      nil
    end

  private

    def warn_about_reviewer_attribution(reviewer_id:, reviewed_at:)
      return if reviewer_id.nil? && reviewed_at.nil?

      NitroIntelligence.deprecator.warn(
        "`reviewer_id` and `reviewed_at` are deprecated and are no longer sent. Assistants does not " \
        "record who reviewed a tool call, so an application that needs the attribution has to keep it " \
        "itself."
      )
    end

    # Assistants accepts `initial_state` on thread creation but never applies it, so a brand new thread is
    # seeded through the thread state endpoint instead. A thread that already exists is left untouched:
    # its state was seeded when it was created and has been built up by every run since.
    def initialize_thread_if_needed(thread_id:, assistant_id:, initial_state:)
      thread_response = create_thread(thread_id:, assistant_id:)

      return if thread_already_exists?(thread_response)
      raise ThreadInitializationError, thread_response.body if thread_response.code.to_i != 200
      return if initial_state.blank?

      seed_new_thread_state(thread_id:, initial_state:)
    end

    # Creating the thread and seeding its state are separate requests, so a failure between them leaves
    # an empty thread behind. A retry would find that thread, take it for one already under way, skip
    # seeding and run without the history -- losing the very thing seeding exists for, without an error.
    # Discard the thread instead, so a retry starts over from a clean slate.
    def seed_new_thread_state(thread_id:, initial_state:)
      seed_thread_state(thread_id:, initial_state:)
    rescue
      discard_thread(thread_id:)
      raise
    end

    def discard_thread(thread_id:)
      delete(path: "/threads/#{thread_id}")
    rescue
      # Best effort. The seeding failure is the one worth surfacing, and it is raised either way.
    end

    def create_thread(thread_id:, assistant_id:)
      post(
        path: "/threads",
        body: {
          threadId: thread_id.to_s,
          ifExists: "raise",
          # Without a graph_id, the thread state cannot be updated before the thread's first run.
          metadata: { graph_id: graph_id_for(assistant_id) },
          user_id:,
        }
      )
    end

    def graph_id_for(assistant_id)
      @graph_ids[assistant_id] ||= fetch_graph_id(assistant_id)
    end

    def fetch_graph_id(assistant_id)
      assistant_response = get(path: "/assistants/#{assistant_id}")

      raise ThreadInitializationError, assistant_response.body if assistant_response.code.to_i != 200

      graph_id = JSON.parse(assistant_response.body)["graph_id"]

      raise ThreadInitializationError, "Assistant #{assistant_id} has no graph_id" if graph_id.blank?

      graph_id
    end

    def seed_thread_state(thread_id:, initial_state:)
      state_response = post(
        path: "/threads/#{thread_id}/state",
        body: { values: { messages: initial_state } }
      )

      raise ThreadInitializationError, state_response.body if state_response.code.to_i != 200

      JSON.parse(state_response.body)
    end

    def thread_already_exists?(response)
      response.code.to_i == THREAD_CONFLICT_CODE
    end

    # The review flows have always raised ThreadResumptionError when a state read fails, and consumers
    # rescue it as such. A plain read resumes nothing, so #thread_state asks for ThreadStateError.
    def get_thread_state(thread_id:, error: ThreadResumptionError)
      state_response = get(path: "/threads/#{thread_id}/state")

      raise error, state_response.body if state_response.code.to_i != 200

      JSON.parse(state_response.body)
    end

    def get_thread(thread_id:)
      thread_response = get(path: "/threads/#{thread_id}")

      raise ThreadResumptionError, thread_response.body if thread_response.code.to_i != 200

      JSON.parse(thread_response.body)
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

      raise RunError, run_response.body if run_response.code.to_i != 200

      run = JSON.parse(run_response.body)
      Array(run["messages"]).last&.dig("content")
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

      raise ThreadResumptionError, run_response.body if run_response.code.to_i != 200

      JSON.parse(run_response.body)
    end

    def interrupted?(thread)
      thread["status"] == "interrupted"
    end

    def messages_in(thread_state)
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
      uri = URI("#{base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      request = Net::HTTP::Get.new(uri)
      request_headers.each { |k, v| request[k] = v }

      http.request(request)
    end

    def delete(path:)
      uri = URI("#{base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      request = Net::HTTP::Delete.new(uri)
      request_headers.each { |k, v| request[k] = v }

      http.request(request)
    end

    def post(path:, body:)
      uri = URI("#{base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      request = Net::HTTP::Post.new(uri)
      request_headers.each { |k, v| request[k] = v }
      request.body = body.to_json

      http.request(request)
    end

    def request_headers
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@api_key}",
      }
    end
  end
end
