# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.2.0-nitro_intelligence...HEAD
[2.2.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.1.0-nitro_intelligence...v2.2.0-nitro_intelligence
[2.1.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v2.0.0-nitro_intelligence...v2.1.0-nitro_intelligence
[2.0.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v1.0.1-nitro_intelligence...v2.0.0-nitro_intelligence
[1.0.1]: https://github.com/powerhome/nitro-intelligence.rb/compare/v1.0.0-nitro_intelligence...v1.0.1-nitro_intelligence
[1.0.0]: https://github.com/powerhome/nitro-intelligence.rb/compare/v0.0.1-nitro_intelligence...v1.0.0-nitro_intelligence
