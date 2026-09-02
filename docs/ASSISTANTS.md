# Nitro Intelligence Assistants

`NitroIntelligence::Assistants` is Nitro Intelligence's Agent management SDK. It wraps the subset of the [Nitro Intelligence Assistants](https://portal.powerapp.cloud/docs/default/system/nip-assistants) API for creating or resuming threads, waiting for agent runs, and supporting human review before tool execution.

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

## `#await_run`

Initializes a thread if needed, seeds it with the prior messages in the conversation, sends the latest message to the agent, and waits for the run to complete.

This is the main entry point when the host application wants to continue a thread and get the assistant's latest response.

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

Returns all tool calls in a thread that are still waiting for human review.

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

Returns the tool calls the thread's interrupt is holding, in the order the platform wants decisions for them, each with the `allowed_decisions` a reviewer may take on it. Empty when the thread is not waiting on a review.

A tool the assistant is not configured to interrupt on runs without review, so one AI message can mix calls under review with calls that are only waiting to be executed. This reports the former; [`#tool_calls_pending_review`](#tool_calls_pending_review) reports both. Only the calls reported here may be passed to [`#review_tool_calls`](#review_tool_calls), and every one of them has to be.

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

`reviewer_id` and `reviewed_at` are deprecated and are no longer sent. Assistants records neither, so an application that needs to know who reviewed a tool call has to keep that itself. Both are still accepted and warn through `NitroIntelligence.deprecator`; they are removed in 3.0.

### Response

Returns `nil` when the thread is resumed successfully.
