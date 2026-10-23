require "json"
require "net/http"
require "uri"
require "nitro_intelligence/pending_review"
require "nitro_intelligence/run_result"
require "nitro_intelligence/tool_call_review_interrupt"
require "nitro_intelligence/tool_call_review_validator"

module NitroIntelligence
  class Assistants
    class ConfigurationError < StandardError; end
    class ThreadInitializationError < StandardError; end
    class RunError < StandardError; end
    class ThreadResumptionError < StandardError; end
    class ThreadStateError < StandardError; end
    # The review being answered is no longer the one the thread is paused on. A subclass, so that
    # callers rescuing ThreadResumptionError still catch it.
    class ReviewSupersededError < ThreadResumptionError; end

    PAUSE_NAMES = { tool_calls: "tool calls", reply: "a reply", delivery: "a delivery" }.freeze

    # What Assistants answers, with a 400, to a resume of a thread that is no longer paused.
    NOT_INTERRUPTED_REFUSAL = "thread is not in interrupted state".freeze

    # Where a `/runs/wait` response says which run it waited on.
    RUN_LOCATION = %r{/runs/([^/]+)\z}

    # Assistants answers with a conflict when `ifExists: "raise"` is sent for a thread that already exists.
    THREAD_CONFLICT_CODE = 409

    # Every assistant this gem is built for is served by the same deployment, so a client told
    # nothing about where to reach one gets that deployment. A host talking to a different one
    # -- a review environment, a local server -- still says so.
    DEFAULT_BASE_URL = "https://assistants.powerhome.ai".freeze

    DEFAULT_USER_ID = "default-user".freeze

    attr_reader :base_url, :user_id

    def initialize(api_key:, base_url: nil, user_id: DEFAULT_USER_ID)
      raise ConfigurationError, "api_key is required" if api_key.blank?
      raise ConfigurationError, "user_id is required" if user_id.blank?

      @base_url = base_url.presence || DEFAULT_BASE_URL
      @api_key = api_key
      @user_id = user_id
      @graph_ids = {}
    end

    # Runs the last of `messages` on the thread, seeding a new thread with the ones before it, and
    # waits for the run to end or pause. A paused run's last AI message is a draft awaiting review,
    # so the result's `reply` is nil whenever it paused; its `review` says what it is waiting on.
    def run(thread_id:, assistant_id:, messages:, context: {})
      raise RunError, "messages cannot be empty" if messages.blank?

      initial_state = messages[0..-2]
      last_message = messages.last

      initialize_thread_if_needed(thread_id:, assistant_id:, initial_state:)
      trigger_run(thread_id:, assistant_id:, context:, last_message:)
    end

    # The run's final reply, or nil when it paused for review or ended without one.
    def await_run(thread_id:, assistant_id:, messages:, context: {})
      run(thread_id:, assistant_id:, messages:, context:).reply
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
    #
    # Raises ThreadResumptionError when the state cannot be read, as it always has; #under_review is
    # the plain read.
    def tool_calls_under_review(thread_id:)
      PendingReview.from_thread_state(get_thread_state(thread_id:))&.tool_calls || []
    end

    # What the thread is paused on -- its tool calls, its reply or a failed delivery -- or nil when
    # it is not waiting on a review.
    def under_review(thread_id:)
      PendingReview.from_thread_state(get_thread_state(thread_id:, error: ThreadStateError))
    end

    # Resumes a paused thread with a reviewer's decision on whatever it is paused on. Pass exactly
    # one of:
    #
    # - `reply:`, a single review of the held draft: `{"action" => "approve"}`,
    #   `{"action" => "edit", "content" => "..."}`, `{"action" => "reject", "message" => "reason"}` or
    #   `{"action" => "respond", "message" => "..."}`;
    # - `delivery:`, a single review of an undelivered reply: `{"action" => "retry"}` delivers the
    #   same text again, `{"action" => "reject", "message" => "reason"}` gives up;
    # - `tool_calls:`, reviews keyed by tool call id, as #review_tool_calls takes them.
    #
    # Every decision sent carries `reviewer_id` and `reviewed_at` (now, unless given), which the
    # platform records on the reply and in Cerebro but never checks.
    #
    # Pass the `interrupt_id` the reviewer was shown (`PendingReview#interrupt_id`). A thread that
    # has moved on -- a new message superseded the review, or another reviewer decided it first --
    # is no longer paused on that interrupt, and the review is refused with ReviewSupersededError
    # rather than applied to whatever the thread is waiting on now. Without it, only the kind of
    # pause is checked.
    #
    # The resume is keyed by the interrupt read here, so a pause that appears between that read and
    # the resume -- a turn's reply after its tool calls, a delivery that fails again at once -- is
    # never decided by it: Assistants leaves the thread paused on the newer interrupt instead. That
    # a stale decision is never applied is guaranteed; reporting it as ReviewSupersededError rather
    # than as a run still paused is best-effort (see PendingReview#unapplied_resume?).
    #
    # Returns the RunResult of the resumed run, which can itself pause: a turn's reply is reviewed
    # after its tool calls, and a reply whose delivery fails pauses again.
    def review(thread_id:, assistant_id:, reviewer_id:, reply: nil, tool_calls: nil, delivery: nil, # rubocop:disable Metrics/ParameterLists
               interrupt_id: nil, reviewed_at: nil, context: {})
      kind, reviews = review_subject!(reply:, tool_calls:, delivery:)
      raise ArgumentError, "reviewer_id is required" if reviewer_id.blank?

      pending_review = pending_review!(thread_id:, kind:, interrupt_id:)
      run = resume_review(thread_id:, assistant_id:, pending_review:, reviews:, reviewer_id:, reviewed_at:, context:)

      RunResult.new(run)
    rescue ThreadResumptionError => e
      raise unless e.message.include?(NOT_INTERRUPTED_REFUSAL)

      # Assistants refuses a resume once the thread is no longer paused, which is how the first of
      # two reviews deciding at once wins. The second is superseded, as the check above reports it.
      superseded!(thread_id, pending_review&.interrupt_id)
    end

    # Resumes an interrupted thread with one review per tool call the interrupt is holding. Each
    # review is keyed by tool call id and names an `action` -- `approve`, `edit`, `reject` or
    # `respond` -- from the decisions the interrupt allows for that tool. `edit` carries `args`,
    # merged over the arguments the model asked for; `respond` carries the `message` returned to the
    # model as the tool's result; `reject` may carry a `message` explaining the refusal.
    #
    # A thin wrapper over what #review sends for `tool_calls:`, keyed by the interrupt it read in the
    # same way, and raising ReviewSupersededError when the resumed run shows the decisions were not
    # applied (see PendingReview#unapplied_resume?). Unlike #review, a resume Assistants refuses
    # because the thread is no longer paused is raised as it always was, a ThreadResumptionError
    # carrying the response body, which nitro-web parses. `reviewer_id` and `reviewed_at` are
    # optional here, and put in each decision when a reviewer is given; #review requires one, checks
    # an `interrupt_id` before resuming and returns the resumed run's result, where this returns nil.
    def review_tool_calls(thread_id:, assistant_id:, tool_calls:, context: {}, reviewer_id: nil, reviewed_at: nil)
      thread = get_thread(thread_id:)
      raise ThreadResumptionError, "Thread #{thread_id} is not in the interrupted state" unless interrupted?(thread)

      pending_review = PendingReview.from_thread_state(get_thread_state(thread_id:))

      if pending_review.nil? || pending_review.tool_calls.empty?
        raise ThreadResumptionError, "Thread #{thread_id} has no tool calls awaiting review"
      end

      resume_review(thread_id:, assistant_id:, pending_review:, reviews: tool_calls, reviewer_id:, reviewed_at:,
                    context:)

      nil
    end

    # ContactCenter::VirtualConfirmationAgent::Client in nitro-web subclasses this to speak the
    # VCA's own review protocol, and its override reaches `get_thread`, `interrupted?`,
    # `get_thread_state` and `resume_run` below. Renaming any of the four breaks that override --
    # loudly, in nitro-web's suite at bump time rather than in anything here. The subclass goes when
    # the VCA moves onto this platform, and this note with it: #run, #under_review and #review are
    # the public calls that replace it, reviewing the VCA's replies as `__reply__` pauses with the
    # reviewer recorded in each decision, and #review_tool_calls takes the `reviewer_id:` and
    # `reviewed_at:` its override adds, so its callers keep working once it is gone. `resume_run`
    # still returns the raw response for it.
  private

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

    # The review flows have always raised ThreadResumptionError when a state read fails, and consumers
    # rescue it as such. A plain read resumes nothing, so #thread_state asks for ThreadStateError.
    def get_thread_state(thread_id:, error: ThreadResumptionError)
      parse!(get(path: "/threads/#{thread_id}/state"), error)
    end

    def get_thread(thread_id:)
      parse!(get(path: "/threads/#{thread_id}"), ThreadResumptionError)
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

    def review_subject!(reply:, tool_calls:, delivery:)
      subjects = { reply:, tool_calls:, delivery: }.compact
      return subjects.first if subjects.one?

      raise ArgumentError, "pass exactly one of reply:, tool_calls: or delivery:"
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
              "Thread #{thread_id} is awaiting review of #{PAUSE_NAMES[pending_review.kind]}, " \
              "not of #{PAUSE_NAMES[kind]}"
      end

      pending_review
    end

    # The decisions for `reviews`, validated against the pause and stamped with the reviewer when
    # there is one, sent as the resume keyed by the pause's interrupt. Raises ReviewSupersededError
    # when the run shows the decisions were not applied.
    def resume_review(thread_id:, assistant_id:, pending_review:, reviews:, reviewer_id:, reviewed_at:, context:) # rubocop:disable Metrics/ParameterLists
      decisions = pending_review.decisions(reviews)
      if reviewer_id.present?
        stamp = { "reviewer_id" => reviewer_id.to_s, "reviewed_at" => review_time(reviewed_at) }
        decisions = decisions.map { |decision| decision.merge(stamp) }
      end

      run, run_id = resume_run_with_id(thread_id:, assistant_id:, resume: pending_review.resume(decisions), context:)
      return run unless pending_review.unapplied_resume?(run:, run_id:) { get_thread_state(thread_id:) }

      superseded!(thread_id, pending_review.interrupt_id, now_paused_on: PendingReview.from_run(run).interrupt_id)
    end

    def superseded!(thread_id, interrupt_id, now_paused_on: nil)
      message = "Thread #{thread_id} is no longer paused on #{interrupt_id.presence || 'a review'}: " \
                "another review already resumed it, or a new message superseded it"
      message += "; it is now paused on #{now_paused_on}, and the decision was not applied" if now_paused_on

      raise ReviewSupersededError, message
    end

    def review_time(reviewed_at)
      return reviewed_at if reviewed_at.is_a?(String)

      (reviewed_at || Time.now).utc.iso8601
    end

    def raise_run_error!(run, error)
      failure = run["__error__"]
      return if failure.blank?

      detail = failure.is_a?(Hash) ? [failure["error"], failure["message"]].compact.join(": ") : failure.to_s
      raise error, detail
    end

    def resume_run(thread_id:, assistant_id:, resume:, context:)
      resume_run_with_id(thread_id:, assistant_id:, resume:, context:).first
    end

    # The resumed run's response, and the id of the run Assistants created for it.
    def resume_run_with_id(thread_id:, assistant_id:, resume:, context:)
      wait_for_run(thread_id:, body: { assistant_id:, command: { resume: }, context: }, error: ThreadResumptionError)
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
