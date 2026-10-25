# Nitro Intelligence Assistants

`NitroIntelligence::Assistants` is Nitro Intelligence's Agent management SDK. It wraps the subset of the [Nitro Intelligence Assistants](https://portal.powerapp.cloud/docs/default/system/nip-assistants) API for creating or resuming threads, waiting for agent runs, and supporting human review of tool calls and replies before they take effect.

For the service itself — the assistants and graphs it hosts, how threads and their state behave, and the human-in-the-loop model this SDK drives — see the [Nitro Intelligence Assistants documentation](https://portal.powerapp.cloud/docs/default/system/nip-assistants). This page covers only the Ruby client.

Most callers should build an instance through Nitro Intelligence configuration:

```ruby
assistants = NitroIntelligence.assistants
```

## `#initialize`

Creates a configured `NitroIntelligence::Assistants` client.

In most app code, you should prefer `NitroIntelligence.assistants`, which reads the credentials from `NitroIntelligence.configuration.assistants_config`. Direct initialization is useful in tests or low-level integration code.

### Usage example

```ruby
assistants = NitroIntelligence::Assistants.new(
  base_url: "https://assistants.example.com",
  api_key: "test-api-key",
  user_id: "default-user"
)
```

## Upgrading to 4.0

- `#await_run` returns `nil` while the run is paused for review, and when it ended without a reply, rather than the last message's content. That content was a draft awaiting review, a tool-calling turn's working text, or `""`. A reply given as content blocks is returned as its joined text, not the Array. Use [`#run`](#run) to see what a paused run is waiting on.
- Resumes are keyed by the interrupt they answer, `command.resume = {"<interrupt id>" => {"decisions" => [...]}}`. Anything inspecting the resume payload sees the new shape.
- [`#review`](#review) raises `ReviewSupersededError`, a `ThreadResumptionError`, for a review the thread has moved past. Its message, and the validation errors raised before anything is sent, are plain text, not a JSON response body, so code that parses `ThreadResumptionError` messages as JSON has to handle text too.
- Pass `context:` to [`#review`](#review) and [`#review_tool_calls`](#review_tool_calls) when the resumed run has to render the assistant's prompt again.

## `#run`

Initializes a thread if needed, seeds it with the prior messages in the conversation, sends the latest message to the agent, and waits for the run to end or to pause for review. Returns a `NitroIntelligence::RunResult`.

This is the main entry point when the host application wants to continue a thread. Thread initialization and run errors are as described under [`#await_run`](#await_run), which is `run(...).reply`.

| `RunResult` | What it is |
| --- | --- |
| `reply` | The text of the run's reply, always a `String`: content given as a list of blocks is reduced to its text blocks, joined. `nil` while the run is paused, and when it ended without one |
| `interrupted?` | Whether the run paused for review |
| `review` | What the paused run is waiting on, a `NitroIntelligence::PendingReview`; `nil` when it did not pause |
| `delivery` | How the platform delivered the reply through the assistant's delivery tool; `nil` when the reply carries no delivery stamp: no reply, or no delivery tool. Read it with `&.` |
| `messages` | The run's messages as Assistants reports them |
| `raw` | The `/runs/wait` response, unformatted |

A run has at most one reply: its final message, an AI message with text and no tool calls. Text the model writes alongside tool calls is its working text, and is never the reply. So `reply` is `nil`:

- while the run is paused: its last AI message is a draft awaiting review, or a turn whose tool calls are held. Do not send it;
- after a reviewer rejects the reply: the draft is removed, leaving a tool result or the customer's message last, and an earlier turn's text is never returned in its place;
- when the reply is empty or only whitespace;
- when the last message is still stamped as awaiting review (`response_metadata.review.type` is `"pending"`), even if the response reports no pause: nobody has reviewed it.

A run pauses on its tool calls or on its reply, never both at once, and `review` exposes whichever it is:

| `PendingReview` | Present when the run paused on | Fields |
| --- | --- | --- |
| `tool_calls` | Tool calls the assistant holds for review | As [`#tool_calls_under_review`](#tool_calls_under_review) reports them; `[]` otherwise |
| `reply` | The run's reply, when the assistant reviews replies (`__reply__`) | `content` (the draft), `allowed_decisions` (from `approve`, `edit` and `reject`), `description`, `interrupt_id`; `nil` otherwise |

`review.kind` is `:tool_calls` or `:reply`, and `review.interrupt_id` identifies the pause; pass it back to [`#review`](#review) so a superseded review is refused.

When the assistant has a delivery tool, the platform delivers the reply when the run ends, after any review, and stamps the reply's `response_metadata.delivery`. `delivery` reads that stamp:

| `delivery` | What it is |
| --- | --- |
| `status` | `"delivered"`, `"failed"` or `"pending"`; `delivered?`, `failed?` and `pending?` test for each |
| `error` | The tool's error when it failed, otherwise `nil` |
| `attempts` | How many times the platform called the tool |
| `result` | What the tool returned when it succeeded |
| `tool` | The delivery tool's name |
| `delivered_at`, `failed_at` | When the reply was delivered, or when delivery gave up |

A failed delivery is not paused or retried by the client: the platform has already retried it. Alert someone, or let the customer's next message bring an answer to both.

The platform stamps a settled reply `"pending"` just before it starts delivering it, and replaces the stamp with the outcome. A finished run whose reply is still `"pending"` was cut off before delivery recorded an outcome (a crash, a cancel or a timeout), so the reply may not have been sent: treat it as not sent, like a failed one. The next customer message removes it from the conversation, and the model answers both messages.

### Usage example

```ruby
assistant = NitroIntelligence.assistants["virtual-confirmation"]

# Run a turn.
result = assistant.run(thread_id: thread_id, messages: messages, context: context)

result.interrupted?                    # => true, the reply is held for review
result.reply                           # => nil while held
result.review.reply.content            # => "Sure! You're booked for Tuesday at 10am."
result.review.reply.allowed_decisions  # => ["approve", "edit", "reject"]
interrupt_id = result.review.interrupt_id  # keep it with the card the reviewer sees
```

## `#await_run`

[`#run`](#run)'s reply: initializes a thread if needed, seeds it with the prior messages in the conversation, sends the latest message to the agent, and waits for the run to end or pause.

Use it when the host application only wants the assistant's reply. Returns `nil` whenever the run paused for review, never the draft awaiting it, and when the run ended without a reply.

### Usage example

```ruby
assistants = NitroIntelligence.assistants

messages = [
  { role: "user", content: "Hello" },
  { role: "assistant", content: "Hi there!" },
  { role: "user", content: "How are you?" }
]

content = assistants.await_run(
  thread_id: "thread-456",
  assistant_id: "assistant-789",
  messages: messages,
  context: { key: "value" }
)
```

### Response example

```json
"I'm doing well, thank you!"
```

### Run errors

Raises `RunError` when Assistants rejects the run request, and when the run itself fails. The message carries the failure Assistants reported:

```
Error: KeyError: missing variables {'first_name'}
IncompleteRun: Wait ended before the run completed (status: running)
```

Returns `nil` when a run pauses for review, whether or not it drafted text. That is an interruption awaiting human review, not a failure; [`#run`](#run) reports what it is waiting on.

### Thread initialization

`#await_run` treats the last entry in `messages` as the message to run, and everything before it as the conversation the agent should already know about. Getting that history in front of the agent takes three requests, because Assistants accepts an `initial_state` on thread creation but never applies it:

1. `GET /assistants/:assistant_id` resolves the assistant's `graph_id`. A `graph_id` is a graph's *name* (for example `confirmation-agent`), which is not the same as the assistant's id — Assistants fails the state update with `Graph not found` when given an id. The lookup is memoized per client, so it costs one request per assistant rather than one per run.
2. `POST /threads` creates the thread with `ifExists: "raise"` and tags it with that `graph_id` in its metadata. Without the tag, the thread's state cannot be updated before its first run.
3. `POST /threads/:thread_id/state` seeds the thread with the earlier messages.

Because `ifExists` is `raise`, Assistants answers with a `409` when the thread is already there. That is not treated as an error — it means the thread is already under way, so the seeding step is skipped and the run proceeds against the state the thread's earlier runs have built up. Seeding only ever happens once, when the thread is first created; a thread whose conversation consists of a single message has nothing to seed and skips step 3 as well.

## `#thread_state`

Returns a thread's state exactly as Assistants reports it, with no formatting applied.

This is the general-purpose read: the response carries the conversation under `values.messages` alongside whatever else Assistants tracks for the thread, such as pending `interrupts`. Callers that only want the conversation should reach for [`#thread_messages`](#thread_messages) instead.

Raises `ThreadStateError` when the thread state cannot be fetched, carrying the response body from Assistants as the message. A thread that does not exist is one such case.

### Usage example

```ruby
assistants = NitroIntelligence.assistants

state = assistants.thread_state(thread_id: "thread-456")
```

### Response example

```json
{
  "values": {
    "messages": [
      {
        "type": "human",
        "id": "communication-1",
        "content": "Hello"
      },
      {
        "type": "ai",
        "id": "ai-message-1",
        "content": "Hi there!"
      }
    ]
  },
  "next": []
}
```

## `#thread_messages`

Returns a thread's messages exactly as Assistants reports them, oldest first, with no formatting applied.

Each message carries its own `type` — `human`, `ai`, `tool` — which callers map onto the roles their own presentation uses. Returns an empty array for a thread whose state holds no messages.

Raises `ThreadStateError` under the same conditions as [`#thread_state`](#thread_state).

### Usage example

```ruby
assistants = NitroIntelligence.assistants

messages = assistants.thread_messages(thread_id: "thread-456")
```

### Response example

```json
[
  {
    "type": "human",
    "id": "communication-1",
    "content": "Hello"
  },
  {
    "type": "ai",
    "id": "ai-message-1",
    "content": "Hi there!"
  }
]
```

## `#tool_calls_pending_review`

Returns every tool call in a thread that has no result yet, across every AI message that made one.

That is not the same as the set a reviewer may decide on. A tool the assistant is not configured to interrupt on is auto-approved and runs as soon as the thread resumes, so one AI message can mix calls the interrupt is holding with calls that are only waiting to be executed — and both are reported here. A review interface driven from this list offers decisions on calls the interrupt does not hold, and [`#review_tool_calls`](#review_tool_calls) then refuses the whole submission; [`#tool_calls_under_review`](#tool_calls_under_review) reports exactly what may be reviewed.

Each pending tool call has a reference to its `previous_message_id`, which points at the message immediately before the tool-call attempt, which lets clients rebuild the conversation context up until that tool call, allowing reviewers to better judge the sequence of events.

### Usage example

```ruby
assistants = NitroIntelligence.assistants

tool_calls = assistants.tool_calls_pending_review(
  thread_id: "thread-456"
)
```

### Response example

```json
[
  {
    "previous_message_id": "communication-1",
    "id": "tool_call_id_1",
    "name": "lookup_account",
    "args": {}
  },
  {
    "previous_message_id": "communication-1",
    "id": "tool_call_id_2",
    "name": "lookup_orders",
    "args": {
      "status": "open"
    }
  },
  {
    "previous_message_id": "communication-2",
    "id": "tool_call_id_3",
    "name": "lookup_invoices",
    "args": {
      "limit": 5
    }
  }
]
```

## `#tool_calls_under_review`

Returns the tool calls the thread's interrupt is holding, in the order the platform wants decisions for them, each with the `allowed_decisions` a reviewer may take on it. Empty when the thread is not waiting on a review, or is paused on its reply; [`#under_review`](#under_review) reports either. It reads the same as `under_review(...)&.tool_calls || []`, except that it raises `ThreadResumptionError` rather than `ThreadStateError`.

A tool the assistant is not configured to interrupt on runs without review, so one AI message can mix calls under review with calls that are only waiting to be executed. This reports the former; [`#tool_calls_pending_review`](#tool_calls_pending_review) reports both. Only the calls reported here may be passed to [`#review_tool_calls`](#review_tool_calls), and every one of them has to be.

Raises `ThreadResumptionError` when the thread state cannot be fetched, as [`#tool_calls_pending_review`](#tool_calls_pending_review) does, and when the interrupt holds an action for which the thread carries no matching tool call.

### Usage example

```ruby
assistants = NitroIntelligence.assistants

tool_calls = assistants.tool_calls_under_review(
  thread_id: "thread-456"
)
```

### Response example

```json
[
  {
    "previous_message_id": "communication-1",
    "id": "tool_call_id_2",
    "name": "send_invoice",
    "args": {
      "amount": 100
    },
    "allowed_decisions": ["approve", "reject"]
  }
]
```

## `#under_review`

Returns what the thread is paused on, as the `review` of a [`#run`](#run) reports it -- its tool calls or its reply -- or `nil` when the thread is not waiting on a review. Use it to show a reviewer the pending review later, away from the run that paused.

Raises `ThreadStateError` when the thread state cannot be fetched.

### Usage example

```ruby
pending = assistant.under_review(thread_id: thread_id)

pending.kind          # => :tool_calls
pending.tool_calls    # => [{ "id" => "call_1", "name" => "cancel_appointment", "args" => {...}, ... }]
pending.interrupt_id  # => "6f1c..."
```

## `#review`

Resumes a paused thread with a reviewer's decision on whatever it is paused on, and returns the `RunResult` of the resumed run. Pass exactly one of `reply:` or `tool_calls:`, matching the pause, a `reviewer_id`, and, for a reply, the `interrupt_id` of the review the reviewer was shown.

| Pause | Argument | `action` | Fields |
| --- | --- | --- | --- |
| Reply | `reply:`, one review hash | `approve` keeps the draft as written | — |
| | | `edit` replaces it, under the same message id | `content`, required |
| | | `reject` removes it, and the run ends with no reply | `message`, optional: a reason recorded in Cerebro, never shown to the model |
| Tool calls | `tool_calls:`, one review per held call | As [`#review_tool_calls`](#review_tool_calls) takes them | |

The action must be one of the pause's `allowed_decisions`. A reply allows what the assistant's prompt config lists for `__reply__`, from `approve`, `edit` and `reject`; `respond` is never offered for a reply. A review naming an action that is not allowed, or missing a field it needs, raises `ThreadResumptionError` before anything is sent, as does a reply review sent to a thread paused on tool calls, and the other way round.

`reviewer_id` (required) and `reviewed_at` (optional, a `Time` or an ISO 8601 string; now by default) are sent in every decision and in the resume run's `config.metadata`. The platform reads a reply's reviewer from the decision and records it on the reply's `response_metadata.review` and in Cerebro. LangChain drops extra keys in a tool decision, so for tool calls it reads the reviewer from `config.metadata`. It never checks either: who may review is the application's decision.

The resume is sent as:

```json
{
  "assistant_id": "assistant-789",
  "command": {
    "resume": {
      "<interrupt id>": {
        "decisions": [
          {
            "type": "approve",
            "reviewer_id": "jane@example.com",
            "reviewed_at": "2026-10-18T14:03:00Z"
          }
        ]
      }
    }
  },
  "config": {
    "metadata": {
      "reviewer_id": "jane@example.com",
      "reviewed_at": "2026-10-18T14:03:00Z"
    }
  },
  "context": {}
}
```

Pass the `interrupt_id` of the review the reviewer was shown. It is required for a reply: a new customer message can replace the draft the reviewer read with a newer one, and an approval that did not name the review would decide that one instead -- and, with a delivery tool, send it unread. A reply review without it raises `ArgumentError` before any request. For tool calls it is optional. If the thread has moved on since -- a new customer message superseded the review, or another reviewer decided it first -- it is no longer paused on that interrupt, and `#review` raises `ReviewSupersededError` (a `ThreadResumptionError`) rather than applying the decision to whatever the thread is waiting on now. It raises the same when the thread is not paused at all, or its run is under way again. A tool-call review without `interrupt_id` checks only the kind of pause before resuming.

The check and the resume are separate requests, so the thread can move on between them. `#review` keys the resume by the interrupt it read, and Assistants applies a keyed resume to that interrupt only: a stale decision is never applied. Reporting it is best-effort: when the resumed run comes back paused on a different interrupt that sits on a checkpoint another run wrote, `#review` raises `ReviewSupersededError`; when it cannot tell, it returns the result, paused on the newer interrupt with nothing decided. A resume Assistants refuses because another review resumed the thread first is reported as `ReviewSupersededError` too. A tool-call pause reported without an id is resumed unkeyed; a reply pause always has one.

The resumed run can pause again: a run whose tool calls were just decided may go on to hold its reply. Read the returned result as you would [`#run`](#run)'s.

`context` is sent with the resumed run, as for [`#await_run`](#await_run).

### Usage example

```ruby
# Later, from a reviewer's screen: edit the reply the reviewer was shown.
result = assistant.review(
  thread_id: thread_id,
  reviewer_id: current_user.email,
  interrupt_id: interrupt_id,
  reply: { "action" => "edit", "content" => "Sure! Tuesday at 10am works. Reply C to confirm." },
  context: context,
)

result.reply             # => "Sure! Tuesday at 10am works. Reply C to confirm."
result.delivery&.status  # => "delivered" or "failed"; delivery is nil without a delivery tool
result.delivery&.error   # => nil, or the tool's error when it failed

# Or reject it: the run ends with no reply; the message is the reason, for Cerebro only.
assistant.review(
  thread_id: thread_id,
  reviewer_id: current_user.email,
  interrupt_id: interrupt_id,
  reply: { "action" => "reject", "message" => "Wrong appointment; I'll call the customer." },
  context: context,
)

# Tool calls: one decision per held call, as today.
pending = assistant.under_review(thread_id: thread_id)
pending.tool_calls  # => [{ "id" => "call_1", "name" => "cancel_appointment", "args" => {...} }]
assistant.review(
  thread_id: thread_id,
  reviewer_id: current_user.email,
  tool_calls: [{ "id" => "call_1", "action" => "reject", "message" => "Customer called in" }],
  context: context,
)

# Superseded: a new customer message, or another reviewer, got there first.
begin
  assistant.review(thread_id: thread_id, reviewer_id: current_user.email,
                   interrupt_id: pending.interrupt_id, reply: { "action" => "approve" },
                   context: context)
rescue NitroIntelligence::Assistants::ReviewSupersededError
  # Reload the thread and show the current pause, if any.
end
```

## `#review_tool_calls`

Resumes an interrupted thread after a human has reviewed the tool calls it is holding.

This method fetches the thread to confirm its `status` is still `interrupted`, loads the current thread state, validates the reviews against the interrupt, and resumes the run with one decision per tool call awaiting review.

Reviews are keyed by tool call id, as returned by [`#tool_calls_under_review`](#tool_calls_under_review), or given as a list of reviews that each carry their tool call's `id`. Each names an `action`, which must be one the interrupt allows for that tool:

| `action` | What it does | Fields |
| --- | --- | --- |
| `approve` | Runs the call as the model asked | — |
| `edit` | Runs the call with the reviewer's arguments | `args`, merged over the arguments the model asked for |
| `reject` | Skips the call; the model sees a fixed, neutral notice | `message`, optional: a reason recorded in Cerebro, never shown to the model |
| `respond` | Skips the call and returns the message to the model as the tool's result | `message`, required |

An `edit` merges by top-level argument name: each argument the reviewer supplies replaces the model's value for it outright — a nested object is not merged into — and every argument left out keeps the value the model sent.

Which actions are allowed for a tool is configured on the assistant's prompt, in Cerebro, and published on the interrupt. A review naming an action the interrupt does not allow raises `Assistants::ThreadResumptionError` before anything is sent, as does a review that omits one of the tool calls under review, edits an argument the call does not have, or leaves out a message `respond` needs.

### Usage example

```ruby
assistants = NitroIntelligence.assistants

assistants.review_tool_calls(
  thread_id: "thread-456",
  assistant_id: "assistant-789",
  tool_calls: {
    "tool_call_id_1" => {
      "action" => "approve"
    },
    "tool_call_id_2" => {
      "action" => "edit",
      "args" => {
        "arg_1" => "new value"
      }
    },
    "tool_call_id_3" => {
      "action" => "reject",
      "message" => "That is the wrong account"
    }
  }
)
```

`context` is optional and is sent with the resumed run, exactly as it is for `#await_run`. Pass the `prompt_variables` the assistant's prompt needs if the resumed run has to render it again.

`reviewer_id` and `reviewed_at` are optional. Given a `reviewer_id`, each decision and the resume run's `config.metadata` carry both, as [`#review`](#review) sends them (`reviewed_at` is now unless given), and the platform records the reviewer from the metadata; without one, neither is sent.

This method is a thin wrapper over the resume [`#review`](#review) sends for `tool_calls:`. It keys the resume by the interrupt it read, so it never decides a pause that appeared in between, and when the resumed run shows it decided nothing it raises `ReviewSupersededError` (a `ThreadResumptionError`). Unlike `#review`, it does not translate Assistants refusing the resume because the thread is no longer paused: that is raised as before, a `ThreadResumptionError` whose message is the response body. `#review` with `tool_calls:` takes the same reviews, requires a reviewer, also checks an `interrupt_id` before resuming, and returns the resumed run's result.

### Response

Returns `nil` when the thread is resumed successfully.

Raises `ThreadResumptionError` when the resumed run fails.
