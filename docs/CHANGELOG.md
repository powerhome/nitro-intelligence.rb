# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.5.0-nitro_intelligence...HEAD
[2.5.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.4.0-nitro_intelligence...v2.5.0-nitro_intelligence
[2.4.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.3.0-nitro_intelligence...v2.4.0-nitro_intelligence
[2.3.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.2.0-nitro_intelligence...v2.3.0-nitro_intelligence
[2.2.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.1.0-nitro_intelligence...v2.2.0-nitro_intelligence
[2.1.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.0.0-nitro_intelligence...v2.1.0-nitro_intelligence
[2.0.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v1.0.1-nitro_intelligence...v2.0.0-nitro_intelligence
[1.0.1]: https://github.com/powerhome/nitro-intelligence.rb/compare/v1.0.0-nitro_intelligence...v1.0.1-nitro_intelligence
[1.0.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v0.0.1-nitro_intelligence...v1.0.0-nitro_intelligence
