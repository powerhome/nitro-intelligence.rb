# nitro-intelligence.rb

`nitro_intelligence` is the Ruby client for the Nitro Intelligence Platform (NIP), published to rubygems.org. Rails applications use it to reach three NIP services, each defaulting to its shared production deployment in `lib/nitro_intelligence/configuration.rb`:

- **Inference Gateway** (LiteLLM, `https://inference.powerhome.ai`) through [`openai/openai-ruby`](https://github.com/openai/openai-ruby): chat, completions, image generation and editing, audio transcription and text-to-speech. The gem reads gateway-specific response headers (`x-litellm-response-cost`, `x-litellm-call-id`) and sends `x-litellm-trace-id` and `x-litellm-spend-logs-metadata`. The contract it relies on is the parent repository's [`docs/inference-gateway.md`](https://github.com/powerhome/nitro-intelligence/blob/main/docs/inference-gateway.md), [`docs/inference-pricing.md`](https://github.com/powerhome/nitro-intelligence/blob/main/docs/inference-pricing.md) and [`docs/client-observability-policy.md`](https://github.com/powerhome/nitro-intelligence/blob/main/docs/client-observability-policy.md).
- **Cerebro** (Langfuse, `https://cerebro.powerhome.ai`) through [`simplepractice/langfuse-rb`](https://github.com/simplepractice/langfuse-rb): tracing observed generations, prompt fetching with fallbacks, media upload and scoring. Cerebro is deployed from [`powerhome/cerebro`](https://github.com/powerhome/cerebro).
- **NIP Assistants** (Aegra/LangGraph, `https://assistants.powerhome.ai`) over HTTP: running assistant threads and resuming human-in-the-loop tool-call reviews. Assistants are served by [`powerhome/nip-assistants`](https://github.com/powerhome/nip-assistants).

User-facing documentation is `docs/README.md` (configuration and usage) and `docs/ASSISTANTS.md` (the Assistants API). Keep them in step with behaviour changes.

## Where changes live

- `lib/nitro_intelligence/configuration.rb`: configuration keys and their defaults, including the service base URLs.
- `lib/nitro_intelligence/client/`: the inference client. `handlers/` holds one plain handler per modality (chat, image, audio transcription, text-to-speech) and `base_handler.rb` sets the gateway request headers; `handlers/observed/` holds the variants that trace to Cerebro; `observers/langfuse_observer.rb` records generations, cost and usage.
- `lib/nitro_intelligence/observability/`: Cerebro projects, per-project Langfuse clients, prompt resolution and fallbacks, media upload.
- `lib/nitro_intelligence/langfuse_extension.rb`, `langfuse_tracer_provider.rb`, `trace.rb`: extensions to langfuse-rb that allow several Langfuse clients (one per Cerebro project) in one process. Candidates for upstreaming to langfuse-rb.
- `lib/nitro_intelligence/assistants.rb`, `assistant.rb`, `assistant_registry.rb`, `tool_call_review_interrupt.rb`, `tool_call_review_validator.rb`: the NIP Assistants client and the tool-call review protocol.
- `lib/nitro_intelligence/models/`: the model catalog built from `model_config` and the per-modality default models.
- `lib/nitro_intelligence/media/`: image and audio inputs and image generation results.
- `spec/`: RSpec suite, mirroring `lib/` under `spec/lib/`. HTTP is stubbed with WebMock.
- `nitro_intelligence.gemspec`: runtime dependencies. `langfuse-rb` is pinned exactly and `openai` has a floor that the gemspec comment justifies; check upstream behaviour at the pinned version before relying on it.
- `doc/dependency_decisions.yml`: license_finder approvals, checked in CI.

## Development

- `bin/setup` runs `bundle install`. Ruby 3.3 is the minimum and the CI version.
- `bundle exec rake` runs the RSpec suite and then RuboCop, which is what CI runs.
- `bundle exec rubocop` runs only the linter, with `rubocop-powerhome`; `.rubocop_todo.yml` holds existing exclusions.
- `bin/console` opens IRB with the gem loaded, and loads a git-ignored `.console_setup.rb` if present (a place for local credentials and `NitroIntelligence.configure`).

## CI and release

- `.github/workflows/nitro_intelligence.yml` runs on every push and calls the shared `powerhome/github-actions-workflows` `ruby-gem.yml` workflow: `bundle exec rake` on Ruby 3.3, plus a license_finder check against `doc/dependency_decisions.yml`.
- A release is a PR titled `Release X.Y.Z` that bumps `lib/nitro_intelligence/version.rb`, updates `Gemfile.lock` to match, and moves the `## [Unreleased]` entries in `docs/CHANGELOG.md` (Keep a Changelog, Semantic Versioning) under a new `## [X.Y.Z] - YYYY-MM-DD` heading. All three must be in the commit that gets tagged.
- After merge, push a tag named `vX.Y.Z-nitro_intelligence` on that commit, normally by publishing a GitHub release. The same workflow's `release` job runs only for refs containing `refs/tags/v` and the package name `nitro_intelligence`; it runs `rake build release:guard_clean release:rubygem_push`, publishing to rubygems.org with the organisation's `RUBYGEMS_API_KEY` secret. A tag on a commit whose `version.rb` does not carry the new version fails the release.
- There is no staging or production deployment of this repository. A release reaches NIP's users when a consuming application bumps `nitro_intelligence` in its `Gemfile.lock` and deploys. Known consumers are `powerhome/nitro-web` (configured in `config/initializers/nitro_intelligence.rb`, with components declaring the dependency in their gemspecs) and `powerhome/tempo`.
- `agentic-pr-review.yaml` runs an automated review on PRs; the `agentic-review-opt-out` label skips it. `reviewdog.yml`, `stale.yml` and `.github/CODEOWNERS` are managed by `powerhome/software` and are overwritten from there.

## Nitro Intelligence Platform

This repository is one part of the Nitro Intelligence Platform (NIP). The parent repository is [`powerhome/nitro-intelligence`](https://github.com/powerhome/nitro-intelligence). The full set of NIP repositories and the upstream projects they build on, and where each kind of change lands, is in [`docs/operations/repositories.md`](https://github.com/powerhome/nitro-intelligence/blob/main/docs/operations/repositories.md) there. When planning or executing work, consider that whole set: check whether a change here depends on, or requires, a change in a sibling repository, and whether the behaviour in question is actually decided upstream (for this repo, chiefly `openai/openai-ruby` and `simplepractice/langfuse-rb` at the pinned version, and the LiteLLM, Langfuse and Aegra/LangGraph APIs of the services it calls). Name cross-repository follow-ups explicitly in the plan or PR.
