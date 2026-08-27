# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `AgentServer#thread_state` and `AgentServer#thread_messages`: read a thread's state, or just its messages, as the agent server reports them. Consumers displaying an existing conversation no longer have to repeat the request, authentication, parsing and error handling the SDK already does. Both raise the new `AgentServer::ThreadStateError` when the state cannot be fetched; the error raised by the existing review flows is unchanged (#36)
- Send `x-litellm-tags` on observed requests, carrying `cerebro_observability_project_id` and, when a managed prompt was resolved, `cerebro_prompt_name` and `cerebro_prompt_version`, so gateway spend can be aggregated per feature. Set automatically with no caller-facing parameter: it serves whoever operates the gateway, not the feature teams calling this library. Nothing is sent on the unobserved path, and this is unrelated to the `tags` parameter, which tags the observability trace (#71)

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

[Unreleased]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.3.0-nitro_intelligence...HEAD
[2.3.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.2.0-nitro_intelligence...v2.3.0-nitro_intelligence
[2.2.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.1.0-nitro_intelligence...v2.2.0-nitro_intelligence
[2.1.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.0.0-nitro_intelligence...v2.1.0-nitro_intelligence
[2.0.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v1.0.1-nitro_intelligence...v2.0.0-nitro_intelligence
[1.0.1]: https://github.com/powerhome/nitro-intelligence.rb/compare/v1.0.0-nitro_intelligence...v1.0.1-nitro_intelligence
[1.0.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v0.0.1-nitro_intelligence...v1.0.0-nitro_intelligence
