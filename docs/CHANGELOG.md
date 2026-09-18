# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `LangfuseObserver` records two things a handler could not report before: `model_parameters`, the settings a generation ran under, which matter because a prompt config can change them without the caller ever naming them; and a `level` and `status_message` for a response the endpoint answered but did not finish, which defaults to `WARNING` so that a generation cut off at its token ceiling is findable without sitting among the errors. Both are written only when a handler reports them, so handlers adopt them one at a time and every existing observation is unchanged (#123)
- `Client#respond`, calling the responses endpoint, which separates the instruction a model is given from the input it answers instead of folding both into one message list. Each prompt type has a slot of its own as a result: a text prompt becomes the request's `instructions`, a chat prompt opens the `input` with anything the caller passes appended after it, so both types work and neither is flattened into the other. `input` is never defaulted -- omitting it is answered with a `500` and sending an empty one has the gateway invent a turn the caller never wrote -- so a request with nothing to answer raises `Observed::ResponsesHandler::ObservedResponsesPromptError` before any inference happens. Observed generations record the message, the reasoning that preceded it and any tool call under the names a chat generation gives them, alongside the settings the generation ran under, the cached share of its input and the gateway's cost; a generation stopped at its token ceiling is recorded at `WARNING` with the reason rather than passing as a complete one, and a failure the endpoint reports in the body of an otherwise successful response raises. Not yet recommended over `#chat` for production: `previous_response_id` does not work through the gateway, and reasoning tokens are reported as zero even when the response carries reasoning (#122)

## [3.0.2] - 2026-09-15

### Fixed

- Audio transcriptions now handle models that report usage in seconds.

## [3.0.1] - 2026-09-15

### Fixed

- `#chat` accepted a request carrying no user message and sent it to be inferred, where it could only fail. A chat completion needs a turn for the model to answer -- the model's own chat template is what insists on one, and Qwen's raises `No user query found in messages.` -- so the request cost a round trip and came back as a `400` whose body the client could not read, leaving the caller with `status=400` and nothing pointing at the cause. Such a request is now refused before any inference happens, raising `Observed::ChatHandler::ObservedChatPromptError` with the cause it found: a text prompt contributes only a system message and needs a `message:` from the caller, a chat prompt can carry its own user message and should be given one in Cerebro, and a request with neither is told what to pass. A user message with blank content is refused too, which is marginally stricter than templates that accept one, on the grounds that a blank turn is nearly always a caller bug; content arriving as an array of parts is accepted, since a turn carrying only an image is legitimate. Callers wanting a generation driven by an instruction alone should use `#complete`, which applies no chat template (#108)

## [3.0.0] - 2026-09-13

### Added

- `Assistants#tool_calls_under_review`: the tool calls the thread's interrupt is holding, in the order the platform wants decisions for them, each carrying the `allowed_decisions` a reviewer may take on it. A tool the assistant is not configured to interrupt on runs without review, so one AI message can mix calls under review with calls that are only waiting to be executed; `#tool_calls_pending_review` reports both, and only the calls this reports may be reviewed. A review interface reading it no longer has to fetch the thread state and interpret the interrupt itself to know which decisions to offer (#91)
- `Assistants#review_tool_calls` accepts the `reject` and `respond` actions alongside `approve` and `edit`, and takes an optional `context`, sent with the resumed run as `#await_run` sends its own. `reject` skips the call and tells the model why; `respond` skips it and returns the reviewer's `message` to the model as the tool's result. `edit` arguments are merged over the ones the model asked for, so a reviewer correcting one of them cannot drop the rest by omitting them (#91)

### Changed

- The review collaborators follow the protocol under Fixed: `ToolCallReviewValidator#validate!` takes `tool_calls_under_review` in place of `thread_state` and `pending_tool_calls`, reading the permitted actions off the interrupt rather than off the thread state, so the interrupt is interpreted in one place -- the new `ToolCallReviewInterrupt`, which recovers the tool calls an interrupt is holding and builds the decisions that answer them. `Assistant#review_tool_calls` drops `reviewer_id` to match the client it delegates to, and `Assistant` delegates `tool_calls_under_review` alongside the other thread-scoped calls (#91)

### Removed

- `Assistants#review_tool_calls`'s `reviewer_id` and `reviewed_at` arguments, outright rather than through a deprecation: the platform records neither, and the resume payload it accepts has nowhere to carry them. Nothing can be relying on them, since no review could complete at all before this, so there has never been a working call to pass them to; the one consumer that reaches this area, nitro-web's `ContactCenter::VirtualConfirmationAgent::Client`, overrides `#review_tool_calls` entirely. A call still passing either now raises `ArgumentError` (#91)
- `NitroIntelligence::AgentServer`, `NitroIntelligence.agent_server` and the `agent_server_config` setting, deprecated in 2.4.0 for removal in 3.0. A host still on the old names must move to `NitroIntelligence::Assistants`, `NitroIntelligence.assistants` and `assistants_config` before upgrading: the constant now raises `NameError`, the method `NoMethodError`, and `agent_server_config` is neither readable nor writable. A host that set `agent_server_config` and never set `assistants_config` is left with no configuration at all: `assistants_config` defaults to `{}`, and `Assistants.new` takes `api_key` as a required keyword, so the first `NitroIntelligence.assistants` call raises `ArgumentError: missing keyword: :api_key` before a client is built or a request sent. The failure is immediate rather than deferred, but it names the missing keyword rather than the setting that was removed, so migrate before upgrading rather than after the first exception. `NitroIntelligence.deprecator` goes with them: it existed to carry these three names and nothing else, and its horizon was 3.0, so it has no remaining subject. A future deprecation introduces its own deprecator against its own horizon (#102)

### Fixed

- `Assistants#review_tool_calls` speaks the review protocol Assistants actually implements, so an interrupt can be resumed at all. It validated the reviewer's action against `interrupts[0].value.review_actions` and resumed with `{reviewer_id, reviewed_at, tool_calls}`, neither of which exists on the platform: every assistant runs LangChain's `HumanInTheLoopMiddleware`, which publishes `action_requests` and `review_configs` and resumes with `decisions`. The old key made the permitted actions an empty array, so every review failed validation before a request was sent, and the payload would have been rejected by the server had it got that far. Actions are now validated against the interrupt's `review_configs[].allowed_decisions`, and the resume sends one decision per action request, in the order the middleware matches them. Action requests carry no tool call id, so each is matched back onto the tool calls of the thread's last AI message to recover the id reviews are keyed by. The resumed run carries the caller's `context` for the same reason: it sent `interrupts[0].value.context`, another key the platform never publishes, so a resume always sent `{}` -- wrong for an assistant whose prompt has to be rendered again with its `prompt_variables` once the tool has run (#91)
- `Assistants#review_tool_calls` reads the thread state once. It fetched `/threads/{thread_id}/state` directly and then again inside the `#tool_calls_pending_review` call it passed to the validator, so every review cost two reads of the same state -- and the two could disagree, leaving a review validated against one state and resumed against another. The interrupt is now parsed once, from a single read (#91)

## [2.8.0] - 2026-09-13

### Added

- Observed text-to-speech generations carry the inference gateway's cost as `cost_details`, alongside the chat, image and audio-transcription handlers that already did. Speech was the one modality left out: its endpoint returns a bare `StringIO` rather than a typed model, and the OpenAI SDK attached response metadata only to typed models, so the header the gateway reports cost in never reached us. Fixed upstream in openai/openai-ruby#561 and released in 0.86. Usage details are still absent for speech - token counts come from a response body that a binary endpoint does not have - so these generations carry a cost without a usage breakdown (#99)

### Changed

- The minimum `openai` dependency is now 0.86, raised from 0.79. 0.86 is the first release that exposes `last_response` on the binary responses text-to-speech returns, and on anything older the speech cost is silently never recorded rather than failing loudly (#99)

### Fixed

- `Assistants#await_run` raises `Assistants::RunError` when a run fails inside an HTTP 200 response, instead of returning `nil` as if the agent had nothing to say. The wait endpoint streams, so its status is committed before the run finishes and the failure is reported in the body as `__error__`; the message from the run is carried into the exception. A run that never finished raises the same way. `#review_tool_calls` raises `ThreadResumptionError` for the same condition on the run it resumes, which it previously discarded entirely. A run that pauses for human review without producing text still returns `nil`

## [2.7.0] - 2026-09-10

### Changed

- The base URLs of the three services this gem talks to default to their shared deployments: `inference_base_url` to `https://inference.powerhome.ai`, `observability_base_url` to `https://cerebro.powerhome.ai`, and an `assistants_config` entry's `base_url` to `https://assistants.powerhome.ai`. Every consumer set all three identically at boot, and one that forgot got a client built against an empty base URL - a request to a relative path, failing wherever the underlying SDK happened to notice - rather than a clear failure or the deployment it meant. A host reaching a different deployment still says so and is unaffected. The observability default is ungated: a host's development and staging environments report to Cerebro production too, since there is no one-to-one mapping between an application's environment and a Cerebro instance (#98)
- `base_url` is no longer required anywhere in `assistants_config`. `Assistant::ConfigurationError` no longer names it among an entry's missing fields, and `Assistants.new` no longer raises `"base_url is required"`, so both the registry shape and the single-client shape that predates it reach the shared deployment when the configuration names none. That is the point of the change, but it does mean a `base_url` that is absent or misspelled surfaces when a request is made rather than when the client is built (#98)

## [2.6.0] - 2026-09-04

### Added

- Assistants are addressable by name. When `assistants_config` carries a `definitions` hash, `NitroIntelligence.assistants` returns an `AssistantRegistry`, and `NitroIntelligence.assistants["candidate-concierge"]` resolves one `Assistant`: a client built for that assistant's deployment, plus the `assistant_id` that `await_run` and `review_tool_calls` supply on the caller's behalf. The thread-scoped calls (`thread_state`, `thread_messages`, `tool_calls_pending_review`) delegate untouched, and `assistant.client` reaches the underlying client. A host talking to several assistants previously had to build and hold a client per assistant itself and thread an assistant id through every call. Connection settings shared by every assistant sit at the top level of the configuration and each entry overrides them where it needs to, so a single assistant can be pointed at a review deployment without restating the rest. The key an entry is filed under is what it is looked up by, distinct from any `name` the entry carries for display. An entry may carry keys this gem has no use for - a graph id, an observability project - and they are ignored, so a deployment and the application reading it can share one structure. Credentials are plain attributes on the entry: this gem reads no environment and assumes no naming convention, because how a deployment mounts the Secret `nip-operator` writes is each consumer's choice and resolving it here would encode one consumer's wiring for all of them. A name that resolves without `base_url`, `api_key` or `assistant_id` raises `Assistant::ConfigurationError` naming every missing field at once; an unconfigured name raises `AssistantRegistry::UnknownAssistantError` listing the names that are configured (#94)

### Changed

- `NitroIntelligence.assistants` returns an `AssistantRegistry` only when `assistants_config` carries `definitions`. Configuration without it is read exactly as before - as keyword arguments for a single `Assistants` client, which is what `NitroIntelligence.assistants` still returns - so a host that has not reshaped its configuration is unaffected and needs no coordinated release (#94)

## [2.5.0] - 2026-08-29

### Added

- Record the inference gateway's `x-litellm-response-cost` on observed generations as `cost_details`, so the observability platform reports the cost the gateway calculated instead of inferring one from its own per-project model pricing. The gateway is the only component that knows which deployment actually served a request - the same model group can be served by internal capacity or by any of several third-party providers at materially different rates - so a cost inferred downstream duplicates the price table doing the billing and drifts from it silently. Applies to the observed chat, image and audio-transcription handlers. The input and output components are recorded when the gateway sends them; routes whose cost comes from the upstream provider rather than the gateway's own calculation report only a total. A deployment the gateway has no price for sends no cost header at all, and those generations are left without a cost rather than recorded as free, so an unpriced model is never mistaken for a free one (#84)

### Changed

- The minimum `openai` dependency is now 0.79, raised from 0.58. The gateway reports its cost in an HTTP response header, and `last_response` - the only route to a response's headers from a typed model - was added to the OpenAI SDK in 0.79. On an older SDK the cost is silently never recorded rather than failing loudly, so an application holding an older lock would upgrade `nitro_intelligence` and see no cost at all (#84)

### Fixed

- `Reporter#create_dataset_item` raises `Reporter::DatasetItemError` when the write is rejected, instead of returning the failed response as if it had worked. A rejected write - bad credentials, a malformed item, a dataset that does not exist - was indistinguishable from a successful one, so a caller building a dataset could run an experiment against items that were never stored (#78)

## [2.4.0] - 2026-08-28

### Added

- `Assistants#thread_state` and `Assistants#thread_messages`: read a thread's state, or just its messages, as Assistants reports them. Consumers displaying an existing conversation no longer have to repeat the request, authentication, parsing and error handling the SDK already does. Both raise the new `Assistants::ThreadStateError` when the state cannot be fetched; the error raised by the existing review flows is unchanged (#36)

### Changed

- The agent server is now Nitro Intelligence Assistants. `NitroIntelligence::AgentServer` is `NitroIntelligence::Assistants`, `NitroIntelligence.agent_server` is `NitroIntelligence.assistants`, and the `agent_server_config` setting is `assistants_config`. Documentation refers to the service by that name and defers to the [Nitro Intelligence Assistants documentation](https://portal.powerapp.cloud/docs/default/system/nip-assistants) rather than to the underlying Agent Protocol server (#73)

### Deprecated

- `NitroIntelligence::AgentServer`, `NitroIntelligence.agent_server` and the `agent_server_config` setting. Each still works and warns through `NitroIntelligence.deprecator`; all three are removed in 3.0. `NitroIntelligence::AgentServer` resolves to the `Assistants` class itself rather than to a stand-in for it, so `is_a?`, `===`, `rescue` and the nested error constants all keep working against the old name. A host that sets both `assistants_config` and `agent_server_config` gets `assistants_config`, so a stale legacy setting cannot override the one that replaced it (#73)

## [2.3.0] - 2026-08-26

### Added

- Record an observation's `input` before the request runs, so a request that raises still shows what was sent. Image generation is excluded: its input carries base64 payloads that are only replaced with media references on success (#66)
- Mark a failed observation with `level: "ERROR"` and a `status_message` carrying the exception class and message, and record the inference gateway's `x-litellm-call-id` from the error response as observation metadata. Previously a request that raised left an observation carrying only its name, requested model and metadata, with no indication anything had gone wrong. The exception is still re-raised, so caller behaviour is unchanged (#66)
- Send the observation's trace ID to the inference gateway as `x-litellm-trace-id`, so a trace can be matched to a gateway request even when the request fails and never produces a response body. Sent only on the observed path: the trace ID comes from the observation being recorded, never from whatever tracing context happens to be active, so a client built without an `observability_project_slug` sends none even inside an instrumented host (#66)
- Send `metadata` to the inference gateway as `x-litellm-spend-logs-metadata`, so gateway spend can be attributed to the work that caused it. Sent whenever metadata is set, observed or not, and omitted above 4KB to stay within proxy header limits (#66)
- `session_id` and `tags` parameters, forwarded to the observability platform when set (#66)

## [2.2.0] - 2026-08-13

### Added

- `prompt_fallback_name`, `prompt_fallback_label` and `prompt_fallback_version` parameters: name a fallback prompt to use when the requested `prompt_name` is missing or its lookup fails, so a feature can ship a prompt variant without one existing for every caller. The fallback is looked up at its own label and version, inheriting neither from the requested prompt (#61)

### Changed

- The observed chat, audio-transcription, image and text-to-speech handlers resolve prompts through a shared `Observability::PromptResolver` rather than each fetching from the prompt store (#61)

## [2.1.0] - 2026-07-31

### Added

- Tag inference requests with custom NIP headers (#54)
- Resolve an agent thread's graph from its assistant, which the agent server requires before a new thread's state can be seeded. Adds one assistant lookup per client, and raises `ThreadInitializationError` when the assistant cannot be fetched or has no graph (#58)

### Changed

- Remove malformed wait header (#54)

### Fixed

- Seed new agent threads through the thread state endpoint, so the agent's context includes the messages sent before the run (#58)
- Discard a newly created agent thread when seeding its state fails, so a retry seeds it again instead of silently running without the earlier messages (#58)

## [2.0.0] - 2026-05-20

### Added

- Support text-to-speech (#45)

### Changed

- Rely on stricter 'type' key in model_config to infer model type

## [1.0.1] - 2026-05-08

### Changed
- Correct Portal data (#20)
- Make required HTTParty version less strict (#24)

## [1.0.0] - 2026-04-15

### Added
- Support audio transcription (#6)
- Enable agent server to manage human-in-the-loop threads (#6)

### Changed
- Refactor client into multiple handlers, each specific to a type of inference (#6)
- Require Ruby 3.3 or later (#10)
- Upgrade langfuse-rb to 0.7.0. (#12)

[Unreleased]: https://github.com/powerhome/nitro-intelligence.rb/compare/v3.0.2-nitro_intelligence...HEAD
[3.0.2]: https://github.com/powerhome/nitro-intelligence.rb/compare/v3.0.0-nitro_intelligence...v3.0.2-nitro_intelligence
[3.0.1]: https://github.com/powerhome/nitro-intelligence.rb/compare/v3.0.0-nitro_intelligence...v3.0.1-nitro_intelligence
[3.0.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.8.0-nitro_intelligence...v3.0.0-nitro_intelligence
[2.8.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.7.0-nitro_intelligence...v2.8.0-nitro_intelligence
[2.7.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.6.0-nitro_intelligence...v2.7.0-nitro_intelligence
[2.6.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.5.0-nitro_intelligence...v2.6.0-nitro_intelligence
[2.5.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.4.0-nitro_intelligence...v2.5.0-nitro_intelligence
[2.4.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.3.0-nitro_intelligence...v2.4.0-nitro_intelligence
[2.3.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.2.0-nitro_intelligence...v2.3.0-nitro_intelligence
[2.2.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.1.0-nitro_intelligence...v2.2.0-nitro_intelligence
[2.1.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.0.0-nitro_intelligence...v2.1.0-nitro_intelligence
[2.0.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v1.0.1-nitro_intelligence...v2.0.0-nitro_intelligence
[1.0.1]: https://github.com/powerhome/nitro-intelligence.rb/compare/v1.0.0-nitro_intelligence...v1.0.1-nitro_intelligence
[1.0.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v0.0.1-nitro_intelligence...v1.0.0-nitro_intelligence
