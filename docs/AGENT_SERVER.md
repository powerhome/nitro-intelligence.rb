# Agent Server

`NitroIntelligence::AgentServer` is Nitro Intelligence's Agent management SDK. It wraps the subset of the Agent Server API for creating or resuming threads, waiting for agent runs, and supporting human review before tool execution.

Under the hood, this integrates with [Aegra](https://docs.aegra.dev/introduction), a self-hosted Agent Protocol server for running stateful agents. The concepts used by this SDK map closely to Aegra's [threads and state](https://docs.aegra.dev/guides/threads-and-state), [human-in-the-loop](https://docs.aegra.dev/guides/human-in-the-loop), and [thread state API](https://docs.aegra.dev/api-reference/threads/get-thread-state).

Most callers should build an instance through Nitro Intelligence configuration:

```ruby
agent_server = NitroIntelligence.agent_server
```

## `#initialize`

Creates a configured `NitroIntelligence::AgentServer` client.

In most app code, you should prefer `NitroIntelligence.agent_server`, which reads the credentials from `NitroIntelligence.configuration.agent_server_config`. Direct initialization is useful in tests or low-level integration code.

### Usage example

```ruby
agent_server = NitroIntelligence::AgentServer.new(
  base_url: "https://agent-server.example.com",
  api_key: "test-api-key",
  user_id: "default-user"
)
```

## `#await_run`

Initializes a thread if needed, seeds it with the prior messages in the conversation, sends the latest message to the agent, and waits for the run to complete.

This is the main entry point when the host application wants to continue a thread and get the assistant's latest response.

### Usage example

```ruby
agent_server = NitroIntelligence.agent_server

messages = [
  { role: "user", content: "Hello" },
  { role: "assistant", content: "Hi there!" },
  { role: "user", content: "How are you?" }
]

content = agent_server.await_run(
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

`#await_run` treats the last entry in `messages` as the message to run, and everything before it as the conversation the agent should already know about. Getting that history in front of the agent takes three requests, because Aegra accepts an `initial_state` on thread creation but never applies it:

1. `GET /assistants/:assistant_id` resolves the assistant's `graph_id`. A `graph_id` is a graph's *name* (for example `confirmation-agent`), which is not the same as the assistant's id — Aegra fails the state update with `Graph not found` when given an id. The lookup is memoized per client, so it costs one request per assistant rather than one per run.
2. `POST /threads` creates the thread with `ifExists: "raise"` and tags it with that `graph_id` in its metadata. Without the tag, the thread's state cannot be updated before its first run.
3. `POST /threads/:thread_id/state` seeds the thread with the earlier messages.

Because `ifExists` is `raise`, Aegra answers with a `409` when the thread is already there. That is not treated as an error — it means the thread is already under way, so the seeding step is skipped and the run proceeds against the state the thread's earlier runs have built up. Seeding only ever happens once, when the thread is first created; a thread whose conversation consists of a single message has nothing to seed and skips step 3 as well.

## `#thread_state`

Returns a thread's state exactly as the agent server reports it, with no formatting applied.

This is the general-purpose read: the response carries the conversation under `values.messages` alongside whatever else the agent server tracks for the thread, such as pending `interrupts`. Callers that only want the conversation should reach for [`#thread_messages`](#thread_messages) instead.

Raises `ThreadStateError` when the thread state cannot be fetched, carrying the agent server's response body as the message. A thread that does not exist is one such case.

### Usage example

```ruby
agent_server = NitroIntelligence.agent_server

state = agent_server.thread_state(thread_id: "thread-456")
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

Returns a thread's messages exactly as the agent server reports them, oldest first, with no formatting applied.

Each message carries its own `type` — `human`, `ai`, `tool` — which callers map onto the roles their own presentation uses. Returns an empty array for a thread whose state holds no messages.

Raises `ThreadStateError` under the same conditions as [`#thread_state`](#thread_state).

### Usage example

```ruby
agent_server = NitroIntelligence.agent_server

messages = agent_server.thread_messages(thread_id: "thread-456")
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
agent_server = NitroIntelligence.agent_server

tool_calls = agent_server.tool_calls_pending_review(
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

## `#review_tool_calls`

Resumes an interrupted thread after a human has reviewed the pending tool calls.

This method fetches the thread to confirm its `status` is still `interrupted`, loads the current thread state, validates the reviewed tool calls against the pending interrupt state, and resumes the run with the reviewer decision payload plus the interrupt context captured by the agent server.

### Usage example

```ruby
agent_server = NitroIntelligence.agent_server

agent_server.review_tool_calls(
  thread_id: "thread-456",
  assistant_id: "assistant-789",
  reviewer_id: "reviewer-123",
  tool_calls: {
    "tool_call_id_1" => {
      "action" => "approve"
    },
    "tool_call_id_2" => {
      "action" => "edit",
      "args" => {
        "arg_1" => "new value",
        "arg_2" => "original value"
      }
    }
  }
)
```

`reviewed_at` is optional. When omitted, the SDK defaults it to `DateTime.current.iso8601`.

### Response

Returns `nil` when the thread is resumed successfully.
