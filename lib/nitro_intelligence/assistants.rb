require "json"
require "net/http"
require "uri"
require "nitro_intelligence/deprecator"
require "nitro_intelligence/pending_review"
require "nitro_intelligence/run_result"

module NitroIntelligence
  # The client for Nitro Intelligence Assistants: runs assistants on threads, and resumes runs
  # paused for review. Most hosts reach it through {NitroIntelligence.assistants}, or through an
  # {Assistant}, which supplies `assistant_id` itself. See `docs/ASSISTANTS.md`.
  class Assistants
    # Raised by {#initialize} without an `api_key` or `user_id`.
    class ConfigurationError < StandardError; end
    # Raised by {#run} when Assistants refuses to create or seed the thread, or the assistant has no
    # graph. The message is the response body.
    class ThreadInitializationError < StandardError; end
    # Raised by {#run} when Assistants rejects the run, and when the run itself fails. The message
    # carries the failure Assistants reported.
    class RunError < StandardError; end
    # Raised when resuming a thread fails: the thread is not paused on what the review answers, a
    # decision is one the pause does not allow, or Assistants refuses the resume.
    class ThreadResumptionError < StandardError; end
    # Raised by {#thread_state}, {#thread_messages} and {#under_review} when the thread's state cannot
    # be read. The message is the response body.
    class ThreadStateError < StandardError; end
    # The review being answered is no longer the one the thread is paused on. A subclass, so that
    # callers rescuing ThreadResumptionError still catch it.
    class ReviewSupersededError < ThreadResumptionError; end

    # @api private
    # What Assistants answers, with a 400, to a resume of a thread that is no longer paused.
    NOT_INTERRUPTED_REFUSAL = "thread is not in interrupted state".freeze

    # @api private
    # Assistants answers with a conflict when `ifExists: "raise"` is sent for a thread that already exists.
    THREAD_CONFLICT_CODE = 409

    # @api private
    # Where a `/runs/wait` response says which run it waited on.
    RUN_LOCATION = %r{/runs/([^/]+)\z}

    # @api private
    # Every assistant this gem is built for is served by the same deployment, so a client told
    # nothing about where to reach one gets that deployment. A host talking to a different one
    # -- a review environment, a local server -- still says so.
    DEFAULT_BASE_URL = "https://assistants.powerhome.ai".freeze

    # The user threads are created for when a client is given none.
    DEFAULT_USER_ID = "default-user".freeze

    # @return [String] the Assistants deployment this client calls
    attr_reader :base_url
    # @return [String] the user threads are created for
    attr_reader :user_id

    # @param api_key [String] the key Assistants authenticates the client with
    # @param base_url [String, nil] the Assistants deployment to call. Defaults to the shared one.
    # @param user_id [String] the user threads are created for
    # @raise [ConfigurationError] without an `api_key` or `user_id`
    def initialize(api_key:, base_url: nil, user_id: DEFAULT_USER_ID)
      raise ConfigurationError, "api_key is required" if api_key.blank?
      raise ConfigurationError, "user_id is required" if user_id.blank?

      @base_url = base_url.presence || DEFAULT_BASE_URL
      @api_key = api_key
      @user_id = user_id
      @graph_ids = {}
    end

    # Runs the last of `messages` on the thread, seeding a new thread with the ones before it, and
    # waits for the run to end or pause. Returns a RunResult: its `reply` is nil whenever the run
    # paused, and its `review` says what the run is waiting on.
    #
    # @param thread_id [String] the thread, created on its first run
    # @param assistant_id [String] the assistant to run
    # @param messages [Array<Hash>] the conversation, oldest first: the last is run, and the ones
    #   before it seed a new thread
    # @param context [Hash] the run's context, such as the variables its prompt needs
    # @return [RunResult]
    # @raise [RunError] when `messages` is empty, Assistants rejects the run, or the run fails
    # @raise [ThreadInitializationError] when a new thread cannot be created or seeded
    def run(thread_id:, assistant_id:, messages:, context: {})
      raise RunError, "messages cannot be empty" if messages.blank?

      initial_state = messages[0..-2]
      last_message = messages.last

      initialize_thread_if_needed(thread_id:, assistant_id:, initial_state:)
      trigger_run(thread_id:, assistant_id:, context:, last_message:)
    end

    # The run's reply, or nil when it paused for review or ended without one.
    #
    # @deprecated Use {#run}`(...).reply`, which also says why there is no reply, and how the
    #   platform delivered the one there is. Removed in 5.0.
    # @param (see #run)
    # @return [String, nil]
    # @raise (see #run)
    def await_run(thread_id:, assistant_id:, messages:, context: {})
      NitroIntelligence.deprecator.warn(
        "#await_run is deprecated and is removed in 5.0; use #run(...).reply, and read #run's " \
        "interrupted? and review for a run paused for review"
      )
      run(thread_id:, assistant_id:, messages:, context:).reply
    end

    # The thread's state as Assistants reports it, unformatted. Callers that only want the
    # conversation should reach for #thread_messages instead.
    #
    # @param thread_id [String]
    # @return [Hash] the `GET /threads/{id}/state` response
    # @raise [ThreadStateError] when the state cannot be read
    def thread_state(thread_id:)
      get_thread_state(thread_id:, error: ThreadStateError)
    end

    # The thread's messages as Assistants reports them, unformatted, oldest first. Each message
    # carries its own `type` ("human", "ai", "tool", ...), which callers map to their own roles.
    #
    # @param thread_id [String]
    # @return [Array<Hash>]
    # @raise [ThreadStateError] when the state cannot be read
    def thread_messages(thread_id:)
      messages_in(thread_state(thread_id:))
    end

    # Every tool call in the thread that has no result yet, whether or not it is held for review,
    # with the id of the message before it.
    #
    # nitro-web's VirtualConfirmationAgent::Client still reads this, since the VCA's interrupt is not
    # in the platform's shape; it goes when the VCA moves onto the platform.
    #
    # @deprecated A reviewer decides only the calls the interrupt holds, which {#under_review}
    #   reports. Removed in 5.0.
    # @param thread_id [String]
    # @return [Array<Hash>] each with `previous_message_id`, `id`, `name` and `args`
    # @raise [ThreadResumptionError] when the state cannot be read
    def tool_calls_pending_review(thread_id:)
      NitroIntelligence.deprecator.warn(
        "#tool_calls_pending_review is deprecated and is removed in 5.0; use " \
        "#under_review(thread_id:)&.tool_calls for the tool calls awaiting a reviewer's decision"
      )
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
    #
    # Raises ThreadResumptionError when the state cannot be read, as it always has; #under_review is
    # the plain read.
    #
    # @deprecated Use {#under_review}`(thread_id:)&.tool_calls.to_a`, which reports a pause on the
    #   reply as well. Removed in 5.0.
    # @param thread_id [String]
    # @return [Array<Hash>] each with `previous_message_id`, `id`, `name`, `args` and
    #   `allowed_decisions`
    # @raise [ThreadResumptionError] when the state cannot be read
    def tool_calls_under_review(thread_id:)
      NitroIntelligence.deprecator.warn(
        "#tool_calls_under_review is deprecated and is removed in 5.0; use " \
        "#under_review(thread_id:)&.tool_calls.to_a"
      )
      PendingReview.from_thread_state(get_thread_state(thread_id:))&.tool_calls || []
    end

    # What the thread is paused on -- its tool calls or its reply -- or nil when it is not waiting
    # on a review.
    #
    # @param thread_id [String]
    # @return [PendingReview, nil]
    # @raise [ThreadStateError] when the state cannot be read
    def under_review(thread_id:)
      PendingReview.from_thread_state(get_thread_state(thread_id:, error: ThreadStateError))
    end

    # Resumes a paused thread with a reviewer's decision on whatever it is paused on, and returns the
    # RunResult of the resumed run. Pass exactly one of:
    #
    # - `reply:`, a single review of the held draft: `{"action" => "approve"}`,
    #   `{"action" => "edit", "content" => "..."}` or `{"action" => "reject", "message" => "reason"}`;
    # - `tool_calls:`, one review per held tool call, as #review_tool_calls takes them.
    #
    # `reviewer_id` and `reviewed_at` (now, unless given) are sent in the resume run's `config.metadata`,
    # where the platform reads them; it records them and never checks them.
    #
    # Pass the `interrupt_id` the reviewer was shown (`PendingReview#interrupt_id`): a thread no longer
    # paused on it raises ReviewSupersededError instead of applying the decision to whatever the thread
    # waits on now. It is required for a reply, since a new message can replace the draft the
    # reviewer read with another, which an approval without it would decide -- and, with a delivery
    # tool, send unread. For tool calls it is optional. The resume is keyed by the interrupt read
    # here, so it never decides a pause that appeared since; reporting such a resume as
    # ReviewSupersededError is best-effort (see PendingReview#unapplied_resume?), as is reporting one
    # Assistants refuses because another review resumed the thread first.
    #
    # @param thread_id [String]
    # @param assistant_id [String] the assistant the resumed run runs
    # @param reviewer_id [String] who decided, as the host identifies them
    # @param reply [Hash, nil] the review of a held reply
    # @param tool_calls [Array<Hash>, Hash, nil] the reviews of held tool calls: a list of reviews
    #   that each carry their tool call's `id`, or a hash of reviews keyed by tool call id
    # @param interrupt_id [String, nil] the pause the reviewer was shown; required for a reply
    # @param reviewed_at [Time, String, nil] when they decided. Defaults to now.
    # @param context [Hash] the resumed run's context, as for {#run}
    # @return [RunResult] the resumed run
    # @raise [ArgumentError] without exactly one of `reply` and `tool_calls`, without a `reviewer_id`,
    #   or reviewing a reply without an `interrupt_id`
    # @raise [ReviewSupersededError] when the thread is no longer paused on the review answered
    # @raise [ThreadResumptionError] when a decision is not one the pause allows, the thread is paused
    #   on the other kind of review, or the resume fails
    # @example
    #   assistants.review(thread_id:, assistant_id:, reviewer_id: "jane@example.com",
    #                     interrupt_id: pending.interrupt_id, reply: { "action" => "approve" })
    def review(thread_id:, assistant_id:, reviewer_id:, reply: nil, tool_calls: nil, interrupt_id: nil, # rubocop:disable Metrics/ParameterLists
               reviewed_at: nil, context: {})
      kind, reviews = review_subject!(reply:, tool_calls:)
      raise ArgumentError, "reviewer_id is required" if reviewer_id.blank?

      if kind == :reply && interrupt_id.blank?
        raise ArgumentError, "interrupt_id is required to review a reply: pass the interrupt_id of the " \
                             "review the reviewer was shown (PendingReview#interrupt_id)"
      end

      pending_review = pending_review!(thread_id:, kind:, interrupt_id:)
      stamp = reviewer_stamp(reviewer_id, reviewed_at)

      RunResult.new(resume_review(thread_id:, assistant_id:, pending_review:, reviews:, stamp:, context:))
    rescue ThreadResumptionError => e
      raise unless e.message.include?(NOT_INTERRUPTED_REFUSAL)

      # Assistants refuses a resume once the thread is no longer paused, which is how the first of
      # two reviews deciding at once wins. The second is superseded.
      superseded!(thread_id, pending_review&.interrupt_id)
    end

    # Resumes an interrupted thread with one review per tool call the interrupt is holding: a hash
    # keyed by tool call id, or a list of reviews that each carry their tool call's `id`. Each names
    # an `action` -- `approve`, `edit`, `reject` or `respond` -- from the decisions the interrupt
    # allows for that tool. `edit` carries `args`, merged over the arguments the model asked for;
    # `respond` carries the `message` returned to the model as the tool's result; `reject` may carry
    # a `message`, recorded as the reason.
    #
    # A thin wrapper over what #review sends for `tool_calls:`: keyed by the interrupt it read, with
    # `reviewer_id` and `reviewed_at` in `config.metadata` when a reviewer is given, and raising
    # ReviewSupersededError when the resumed run shows the decisions were not applied. Unlike #review,
    # a resume Assistants refuses because the thread is no longer paused is raised as it always was, a
    # ThreadResumptionError carrying the response body, which nitro-web parses. Returns nil.
    #
    # @deprecated Use {#review}`(tool_calls:, reviewer_id:, interrupt_id:)`, which requires the
    #   reviewer and returns the resumed run. Removed in 5.0.
    # @param thread_id [String]
    # @param assistant_id [String]
    # @param tool_calls [Hash, Array<Hash>] the reviews
    # @param context [Hash]
    # @param reviewer_id [String, nil]
    # @param reviewed_at [Time, String, nil]
    # @return [nil]
    # @raise [ReviewSupersededError] when the resumed run shows the decisions were not applied
    # @raise [ThreadResumptionError] when the thread is not paused on tool calls, a decision is not one
    #   the pause allows, or the resume fails
    def review_tool_calls(thread_id:, assistant_id:, tool_calls:, context: {}, reviewer_id: nil, reviewed_at: nil)
      NitroIntelligence.deprecator.warn(
        "#review_tool_calls is deprecated and is removed in 5.0; use " \
        "#review(tool_calls:, reviewer_id:, interrupt_id:), which returns the resumed run's RunResult"
      )
      thread = get_thread(thread_id:)
      raise ThreadResumptionError, "Thread #{thread_id} is not in the interrupted state" unless interrupted?(thread)

      pending_review = PendingReview.from_thread_state(get_thread_state(thread_id:))

      if pending_review.nil? || pending_review.tool_calls.empty?
        raise ThreadResumptionError, "Thread #{thread_id} has no tool calls awaiting review"
      end

      stamp = reviewer_id.present? ? reviewer_stamp(reviewer_id, reviewed_at) : nil
      resume_review(thread_id:, assistant_id:, pending_review:, reviews: tool_calls, stamp:, context:)

      nil
    end

    # ContactCenter::VirtualConfirmationAgent::Client in nitro-web subclasses this to speak the
    # VCA's own review protocol, and its override reaches `get_thread`, `interrupted?`,
    # `get_thread_state` and `resume_run` below. Renaming any of the four breaks that override --
    # loudly, in nitro-web's suite at bump time rather than in anything here. The subclass goes when
    # the VCA moves onto this platform, and this note with it.
    #
    # The four are private to callers and public to subclasses, so they are documented as protected.
  private

    # Reads a thread. For subclasses.
    #
    # @!visibility protected
    # @param thread_id [String]
    # @return [Hash] the `GET /threads/{id}` response
    # @raise [ThreadResumptionError] when the thread cannot be read. The message is the response body.
    def get_thread(thread_id:)
      parse!(get(path: "/threads/#{thread_id}"), ThreadResumptionError)
    end

    # Whether a thread, as {#get_thread} reads it, is paused. For subclasses.
    #
    # @!visibility protected
    # @param thread [Hash]
    # @return [Boolean]
    def interrupted?(thread)
      thread["status"] == "interrupted"
    end

    # Reads a thread's state. For subclasses.
    #
    # The review flows have always raised ThreadResumptionError when a state read fails, and consumers
    # rescue it as such. A plain read resumes nothing, so #thread_state asks for ThreadStateError.
    #
    # @!visibility protected
    # @param thread_id [String]
    # @param error [Class<StandardError>] what to raise when the state cannot be read
    # @return [Hash] the `GET /threads/{id}/state` response
    # @raise [StandardError] `error`, with the response body as its message
    def get_thread_state(thread_id:, error: ThreadResumptionError)
      parse!(get(path: "/threads/#{thread_id}/state"), error)
    end

    # Resumes a paused thread with `resume` as its `command.resume`, sent as given, and waits for the
    # run. For subclasses that build their own resume.
    #
    # @!visibility protected
    # @param thread_id [String]
    # @param assistant_id [String]
    # @param resume [Hash, Array] the `command.resume`
    # @param context [Hash]
    # @return [Hash] the `/runs/wait` response
    # @raise [ThreadResumptionError] when Assistants refuses the resume, with the response body as its
    #   message, or the resumed run fails
    def resume_run(thread_id:, assistant_id:, resume:, context:)
      wait_for_run(thread_id:, body: { assistant_id:, command: { resume: }, context: }, error: ThreadResumptionError)
        .first
    end

    # Assistants accepts `initial_state` on thread creation but never applies it, so a brand new thread is
    # seeded through the thread state endpoint instead. A thread that already exists is left untouched:
    # its state was seeded when it was created and has been built up by every run since.
    def initialize_thread_if_needed(thread_id:, assistant_id:, initial_state:)
      thread_response = create_thread(thread_id:, assistant_id:)

      return if thread_already_exists?(thread_response)

      check!(thread_response, ThreadInitializationError)
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
      graph_id = parse!(get(path: "/assistants/#{assistant_id}"), ThreadInitializationError)["graph_id"]

      raise ThreadInitializationError, "Assistant #{assistant_id} has no graph_id" if graph_id.blank?

      graph_id
    end

    def seed_thread_state(thread_id:, initial_state:)
      parse!(post(path: "/threads/#{thread_id}/state", body: { values: { messages: initial_state } }),
             ThreadInitializationError)
    end

    def thread_already_exists?(response)
      response.code.to_i == THREAD_CONFLICT_CODE
    end

    def trigger_run(thread_id:, assistant_id:, last_message:, context: {})
      run, = wait_for_run(thread_id:, body: { assistant_id:, context:, input: { messages: [last_message] } },
                          error: RunError)
      RunResult.new(run)
    end

    # Waits on a run of the thread, raising `error` when the request fails or the run reports an
    # `__error__`. Returns the run and the id Assistants gave it, which the wait reports in its
    # `Content-Location` (`/threads/{thread_id}/runs/{run_id}`); nil without one.
    def wait_for_run(thread_id:, body:, error:)
      response = post(path: "/threads/#{thread_id}/runs/wait", body:)
      run = parse!(response, error)
      raise_run_error!(run, error)

      [run, response["Content-Location"].to_s[RUN_LOCATION, 1]]
    end

    def raise_run_error!(run, error)
      failure = run["__error__"]
      return if failure.blank?

      detail = failure.is_a?(Hash) ? [failure["error"], failure["message"]].compact.join(": ") : failure.to_s
      raise error, detail
    end

    def review_subject!(reply:, tool_calls:)
      subjects = { reply:, tool_calls: }.compact
      return subjects.first if subjects.one?

      raise ArgumentError, "pass exactly one of reply: or tool_calls:"
    end

    # The thread has to be paused, on the interrupt the reviewer was shown when they say which, and
    # on the kind of review they are answering. A thread whose run is under way again is not
    # paused, whatever its state still reports.
    def pending_review!(thread_id:, kind:, interrupt_id:)
      pending_review = interrupted?(get_thread(thread_id:)) &&
                       PendingReview.from_thread_state(get_thread_state(thread_id:))

      if !pending_review || (interrupt_id.present? && pending_review.interrupt_id != interrupt_id)
        superseded!(thread_id, interrupt_id)
      end

      if pending_review.kind != kind
        raise ThreadResumptionError,
              "Thread #{thread_id} is awaiting review of #{PendingReview::KIND_NAMES[pending_review.kind]}, " \
              "not of #{PendingReview::KIND_NAMES[kind]}"
      end

      pending_review
    end

    def reviewer_stamp(reviewer_id, reviewed_at)
      reviewed_at = (reviewed_at || Time.now).utc.iso8601 unless reviewed_at.is_a?(String)

      { "reviewer_id" => reviewer_id.to_s, "reviewed_at" => reviewed_at }
    end

    # Sends the decisions for `reviews`, validated against the pause, as the resume keyed by the
    # pause's interrupt. A reviewer `stamp` goes in the run's `config.metadata`, where the platform
    # reads it for replies and tool calls alike (LangChain drops extra keys in a tool decision).
    # Raises ReviewSupersededError when the run shows the decisions were not applied.
    def resume_review(thread_id:, assistant_id:, pending_review:, reviews:, stamp:, context:)
      decisions = pending_review.decisions(reviews)

      body = { assistant_id:, command: { resume: pending_review.resume(decisions) } }
      body[:config] = { metadata: stamp } if stamp
      body[:context] = context

      run, run_id = wait_for_run(thread_id:, body:, error: ThreadResumptionError)
      return run unless pending_review.unapplied_resume?(run:, run_id:) { get_thread_state(thread_id:) }

      superseded!(thread_id, pending_review.interrupt_id, now_paused_on: PendingReview.from_run(run).interrupt_id)
    end

    def superseded!(thread_id, interrupt_id, now_paused_on: nil)
      message = "Thread #{thread_id} is no longer paused on #{interrupt_id.presence || 'a review'}: " \
                "another review already resumed it, or a new message superseded it"
      message += "; it is now paused on #{now_paused_on}, and the decision was not applied" if now_paused_on

      raise ReviewSupersededError, message
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
      request(Net::HTTP::Get, path:)
    end

    def delete(path:)
      request(Net::HTTP::Delete, path:)
    end

    def post(path:, body:)
      request(Net::HTTP::Post, path:, body:)
    end

    def request(verb, path:, body: nil)
      uri = URI("#{base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      request = verb.new(uri)
      request_headers.each { |k, v| request[k] = v }
      request.body = body.to_json unless body.nil?

      http.request(request)
    end

    # Anything but a 200 is a failure, raised as `error` with the response body as its message.
    # Thread creation tells a conflict apart before it gets here.
    def check!(response, error)
      raise error, response.body if response.code.to_i != 200

      response
    end

    def parse!(response, error)
      JSON.parse(check!(response, error).body)
    end

    def request_headers
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@api_key}",
      }
    end
  end
end
