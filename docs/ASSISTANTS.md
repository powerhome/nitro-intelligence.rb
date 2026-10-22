# Nitro Intelligence Assistants

`NitroIntelligence::Assistants` is Nitro Intelligence's Agent management SDK. It wraps the subset of the [Nitro Intelligence Assistants](https://portal.powerapp.cloud/docs/default/system/nip-assistants) API for creating or resuming threads, waiting for agent runs, and supporting human review of tool calls and replies before they take effect, and of replies the platform could not deliver.

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

## `#run`

Initializes a thread if needed, seeds it with the prior messages in the conversation, sends the latest message to the agent, and waits for the run to end or to pause for review. Returns a `NitroIntelligence::RunResult`.

This is the main entry point when the host application wants to continue a thread. Thread initialization and run errors are as described for [`#await_run`](#await_run), which is `run(...).reply`.

| `RunResult` | What it is |
| --- | --- |
| `reply` | The text of the run's final reply. `nil` whenever the run paused, and when it ended without one (a rejected reply, or a run whose last message is not the assistant's) |
| `interrupted?` | Whether the run paused for review |
| `review` | What the paused run is waiting on, a `NitroIntelligence::PendingReview`; `nil` when it did not pause |
| `messages` | The run's messages as Assistants reports them |
| `raw` | The `/runs/wait` response, unformatted |

A paused run's last AI message is a draft awaiting review, never the reply: Assistants marks a paused run with `__interrupt__`, and a reply is final only once a run ends without it. Do not send the draft.

A run pauses on one of three things, never more than one at a time, and `review` exposes whichever it is:

| `PendingReview` | Present when the run paused on | Fields |
| --- | --- | --- |
| `tool_calls` | Tool calls the assistant holds for review | As [`#tool_calls_under_review`](#tool_calls_under_review) reports them; `[]` otherwise |
| `reply` | The reply, when the assistant reviews replies (`__reply__`) | `content` (the draft), `allowed_decisions`, `description`, `interrupt_id`; `nil` otherwise |
| `delivery` | A settled reply its delivery tool kept failing to send (`__delivery__`) | `content`, `message_id`, `error`, `attempts`, `allowed_decisions`, `description`, `interrupt_id`; `nil` otherwise |

`review.kind` is `:tool_calls`, `:reply` or `:delivery`, and `review.interrupt_id` identifies the pause; pass it back to [`#review`](#review) so a superseded review is refused.

A model turn with both text and a held tool call pauses twice: on its tool calls first, with `review.reply` `nil` (the draft text is already in the thread's messages, for a reviewer to read), and then, once they are decided, on its text.

### Usage example

```ruby
assistant = NitroIntelligence.assistants["virtual-confirmation"]

result = assistant.run(
  thread_id: "thread-456",
  messages: messages,
  context: { key: "value" }
)

result.interrupted?                    # => true
result.reply                           # => nil, the draft is held
result.review.reply.content            # => "Sure! You're booked for Tuesday at 10am."
result.review.reply.allowed_decisions  # => ["approve", "edit", "reject"]
```

## `#await_run`

[`#run`](#run)'s reply: initializes a thread if needed, seeds it with the prior messages in the conversation, sends the latest message to the agent, and waits for the run to end or pause.

Use it when the host application only wants the assistant's final response. Returns `nil` whenever the run paused for review -- never the draft awaiting it -- and when the run ended without a reply.

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

Returns the tool calls the thread's interrupt is holding, in the order the platform wants decisions for them, each with the `allowed_decisions` a reviewer may take on it. Empty when the thread is not waiting on a review, or is paused on a reply or a delivery rather than on tool calls; [`#under_review`](#under_review) reports any of them.

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

Returns what the thread is paused on, as the `review` of a [`#run`](#run) reports it -- tool calls, a reply or an undelivered reply -- or `nil` when the thread is not waiting on a review. Use it to show a reviewer the pending review later, away from the run that paused.

Raises `ThreadStateError` when the thread state cannot be fetched.

### Usage example

```ruby
pending = assistant.under_review(thread_id: "thread-456")

pending.kind                # => :delivery
pending.delivery.content    # => "Great, see you Thursday at 9am!"
pending.delivery.error      # => "Quiet hours: messages can't be sent before 8am"
pending.delivery.attempts   # => 3
pending.interrupt_id        # => "6f1c..."
```

## `#review`

Resumes a paused thread with a reviewer's decision on whatever it is paused on, and returns the `RunResult` of the resumed run. Pass exactly one of `reply:`, `delivery:` or `tool_calls:`, matching the pause, and a `reviewer_id`.

| Pause | Argument | `action` | Fields |
| --- | --- | --- | --- |
| Reply | `reply:` | `approve` keeps the draft | — |
| | | `edit` replaces it, same message id | `content`, required |
| | | `respond` replaces it with a reply the reviewer wrote | `message`, required |
| | | `reject` removes it; any tool calls left in the turn still run, otherwise the run ends with no reply | `message`, optional: a reason recorded in Cerebro, never shown to the model |
| Delivery | `delivery:` | `approve` retries with the same text | — |
| | | `edit` delivers the new text instead, under the same message id | `content`, required |
| | | `reject` gives up and removes the reply | `message`, optional reason |
| Tool calls | `tool_calls:` | As [`#review_tool_calls`](#review_tool_calls) takes them, keyed by tool call id | |

The action must be one of the pause's `allowed_decisions`. A reply allows what the assistant's prompt config lists for `__reply__`; a delivery always allows `approve`, `edit` and `reject`. A review naming an action that is not allowed, or missing a field it needs, raises `ThreadResumptionError` before anything is sent.

`reviewer_id` (required) and `reviewed_at` (optional, a `Time` or an ISO 8601 string; now by default) are sent in every decision, which is where the platform reads them. It records them on the reply's `response_metadata.review` and in Cerebro, and never checks them: who may review is the application's decision.

Pass the `interrupt_id` of the review the reviewer was shown. If the thread has moved on since -- a new message superseded the review, or another reviewer decided it first -- it is no longer paused on that interrupt, and `#review` raises `ReviewSupersededError` (a `ThreadResumptionError`) rather than applying the decision to whatever the thread is waiting on now. It raises the same when the thread is not paused at all, or its run is under way again. Without `interrupt_id`, only the kind of pause is checked: a reply review sent to a thread paused on tool calls raises `ThreadResumptionError`, but a reply review would decide a newer draft. The check and the resume are separate requests, so two reviewers deciding at the same instant can both pass it. Assistants accepts the first resume and refuses any other while the thread is no longer paused, and `#review` reports that refusal as `ReviewSupersededError` too: the first resume wins.

The resumed run can pause again: a turn whose tool calls were just decided pauses on its text, and a reply whose delivery fails pauses on the delivery. Read the returned result as you would [`#run`](#run)'s.

`context` is sent with the resumed run, as for [`#await_run`](#await_run).

### Usage example

```ruby
assistant = NitroIntelligence.assistants["virtual-confirmation"]
pending = assistant.under_review(thread_id: thread_id)

# Edit the reply.
result = assistant.review(
  thread_id: thread_id,
  reviewer_id: current_user.email,
  interrupt_id: pending.interrupt_id,
  reply: {
    "action" => "edit",
    "content" => "Sure! Tuesday at 10am works. Reply C to confirm.",
  },
  context: context
)
result.reply # => "Sure! Tuesday at 10am works. Reply C to confirm."

# Or reject it: the run ends with no reply, and the message is the reason.
assistant.review(
  thread_id: thread_id,
  reviewer_id: current_user.email,
  interrupt_id: pending.interrupt_id,
  reply: {
    "action" => "reject",
    "message" => "Wrong appointment; I'll call the customer.",
  },
  context: context
)

# Retry a failed delivery from a background job once quiet hours are over.
assistant.review(
  thread_id: thread_id,
  reviewer_id: "delivery-retry-job",
  interrupt_id: pending.interrupt_id,
  delivery: { "action" => "approve" },
  context: context
)
```

## `#review_tool_calls`

Resumes an interrupted thread after a human has reviewed the tool calls it is holding.

This method fetches the thread to confirm its `status` is still `interrupted`, loads the current thread state, validates the reviews against the interrupt, and resumes the run with one decision per tool call awaiting review.

Reviews are keyed by tool call id, as returned by [`#tool_calls_under_review`](#tool_calls_under_review). Each names an `action`, which must be one the interrupt allows for that tool:

| `action` | What it does | Fields |
| --- | --- | --- |
| `approve` | Runs the call as the model asked | — |
| `edit` | Runs the call with the reviewer's arguments | `args`, merged over the arguments the model asked for |
| `reject` | Skips the call and tells the model why | `message`, optional |
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

`reviewer_id` and `reviewed_at` are optional. Given a `reviewer_id`, each decision carries both, as [`#review`](#review) sends them (`reviewed_at` is now unless given); without one, the decisions carry neither. `#review` with `tool_calls:` takes the same reviews, requires a reviewer, refuses a superseded review and returns the resumed run's result; this method is a thin wrapper that returns `nil`.

### Response

Returns `nil` when the thread is resumed successfully.

Raises `ThreadResumptionError` when the resumed run fails.
