# End-to-end specs: the real client against the real inference gateway and Cerebro, with nothing
# stubbed. Each feature is exercised as an application uses it, with observability on, and checked
# end to end: what it returned, how Cerebro recorded it, and what the gateway charged for it. They make
# billable model calls, so they run through `rake e2e` or by naming their files, never in the default
# suite (see spec_helper.rb), and need a gateway key and the Cerebro project's credentials.
#
# Assertions check what any working model must get right, not exact wording, so that a model
# upgrade behind the gateway does not fail them while a broken request or response contract does.
require "active_support/core_ext/object/blank"
require "securerandom"
require_relative "cerebro_reader"

module E2eHelpers
  API_KEY_VARIABLE = "NIP_E2E_INFERENCE_API_KEY".freeze
  BASE_URL_VARIABLE = "NIP_E2E_INFERENCE_BASE_URL".freeze

  TEXT_MODEL = "Qwen/Qwen3.6-35B-A3B".freeze
  AUDIO_TRANSCRIPTION_MODEL = "Qwen/Qwen3-ASR-1.7B".freeze
  TEXT_TO_SPEECH_MODEL = "google/gemini-3.8-flash-lite-tts".freeze
  IMAGE_MODEL = "google/gemini-3.1-flash-image".freeze
  DECISION_MODEL = "typesafe/jev-1.14".freeze
  EMBEDDING_MODEL = "Qwen/Qwen3-Embedding-0.6B".freeze
  RERANK_MODEL = "Qwen/Qwen3-Reranker-0.6B".freeze

  MODEL_CONFIG = {
    "default_text_model" => TEXT_MODEL,
    "default_audio_transcription_model" => AUDIO_TRANSCRIPTION_MODEL,
    "default_text_to_speech_model" => TEXT_TO_SPEECH_MODEL,
    "default_image_model" => IMAGE_MODEL,
    "default_decision_model" => DECISION_MODEL,
    "default_embedding_model" => EMBEDDING_MODEL,
    "default_rerank_model" => RERANK_MODEL,
    "models" => [
      { "name" => TEXT_MODEL, "type" => "text" },
      { "name" => AUDIO_TRANSCRIPTION_MODEL, "type" => "audio_transcription" },
      {
        "name" => TEXT_TO_SPEECH_MODEL,
        "type" => "text_to_speech",
        "default_voice" => "Kore",
        "default_response_format" => "wav",
        "voices" => ["Kore"],
        "response_formats" => ["wav"],
      },
      {
        "name" => IMAGE_MODEL,
        "type" => "image",
        "aspect_ratios" => ["1:1"],
        "resolutions" => ["512"],
        "omit_output_fields" => ["provider_specific_fields.thought_signatures"],
      },
      { "name" => DECISION_MODEL, "type" => "decision" },
      {
        "name" => EMBEDDING_MODEL,
        "type" => "embedding",
        "query_prefix" => "Instruct: Given a web search query, retrieve relevant passages that answer the " \
                          "query\nQuery:",
      },
      { "name" => RERANK_MODEL, "type" => "rerank" },
    ],
  }.freeze

  OBSERVABILITY_PROJECT_SLUG = "ruby-sdk-e2e".freeze
  # The same Cerebro project, configured to mask content, as an application handling sensitive data
  # configures its own.
  MASKED_OBSERVABILITY_PROJECT_SLUG = "ruby-sdk-e2e-masked".freeze
  OBSERVABILITY_VARIABLES = {
    "id" => "NIP_E2E_OBSERVABILITY_PROJECT_ID",
    "public_key" => "NIP_E2E_OBSERVABILITY_PUBLIC_KEY",
    "secret_key" => "NIP_E2E_OBSERVABILITY_SECRET_KEY",
  }.freeze

  def self.configure!
    NitroIntelligence.configure do |config|
      config.logger = Logger.new(nil)
      config.inference_api_key = required_variables(API_KEY_VARIABLE).fetch(API_KEY_VARIABLE)
      config.inference_base_url = ENV[BASE_URL_VARIABLE] if ENV[BASE_URL_VARIABLE].present?
      config.model_config = MODEL_CONFIG
      config.observability_projects = observability_projects
    end
  end

  # The "Ruby SDK End-to-End Tests" Cerebro project, which powerhome/software provisions along with
  # these credentials.
  def self.observability_projects
    variables = required_variables(*OBSERVABILITY_VARIABLES.values)
    credentials = OBSERVABILITY_VARIABLES.transform_values { variables.fetch(_1) }

    [
      credentials.merge("slug" => OBSERVABILITY_PROJECT_SLUG),
      credentials.merge("slug" => MASKED_OBSERVABILITY_PROJECT_SLUG, "mask_content" => true),
    ]
  end

  def self.required_variables(*names)
    values = names.index_with { ENV.fetch(_1, "") }
    missing = values.select { |_, value| value.empty? }.keys
    return values if missing.empty?

    raise "#{missing.join(', ')} not set. The end-to-end specs call the real inference gateway and " \
          "record to a real Cerebro project, and need credentials for both."
  end

  def cerebro
    @cerebro ||= CerebroReader.new(
      NitroIntelligence.project_client_registry.fetch(OBSERVABILITY_PROJECT_SLUG).project
    )
  end

  # Exports what the client has recorded so far, so Cerebro can ingest it.
  def flush_observations
    NitroIntelligence.project_client_registry.fetch(OBSERVABILITY_PROJECT_SLUG).flush(timeout: 30)
    NitroIntelligence.project_client_registry.fetch(MASKED_OBSERVABILITY_PROJECT_SLUG).flush(timeout: 30)
  end

  # A trace of the spec's own, so whatever is read back can only be this run's.
  def new_trace_seed
    "nitro-intelligence.rb-e2e-#{SecureRandom.uuid}"
  end

  # Spend logs on the gateway carry this, so the suite's cost can be told apart from real usage.
  def e2e_metadata
    { source: "nitro-intelligence.rb e2e", github_run_id: ENV.fetch("GITHUB_RUN_ID", "local") }
  end

  def cosine_similarity(left, right)
    dot = left.zip(right).sum { |a, b| a * b }
    dot / (Math.sqrt(left.sum { _1**2 }) * Math.sqrt(right.sum { _1**2 }))
  end

  def words(text)
    text.downcase.scan(/[a-z]+/)
  end
end

# What a recorded request must show in Cerebro, whatever the feature.
module E2eExpectations
  # The cost of a request, as the gateway charged it.
  def gateway_cost(response)
    Float(response.last_response.headers.fetch("x-litellm-response-cost"))
  end

  def observation_named(observations, name)
    matches = observations.select { _1["name"] == name }
    expect(matches.size).to eq(1), "expected one #{name.inspect} observation, got #{observations.pluck('name')}"
    matches.first
  end

  # Cerebro records a breakdown of the input or output, such as cached or reasoning tokens, apart
  # from the rest of it, so the parts add up to the total the gateway reported.
  def expect_usage(observation, total:)
    usage = observation.fetch("usageDetails")
    expect(usage["total"]).to eq(total)
    expect(usage.except("total").values.sum).to eq(total)
  end

  def expect_cost(observation, cost)
    expect(cost).to be_positive
    expect(observation.dig("costDetails", "total")).to be_within(1e-9).of(cost)
    expect(observation["totalCost"]).to be_within(1e-9).of(cost)
  end
end

RSpec.configure do |config|
  config.include E2eHelpers, :e2e
  config.include E2eExpectations, :e2e

  # Other specs loaded in the same process load webmock/rspec, which blocks real requests. The e2e
  # groups lift that and put back whatever was in force before, allowances included.
  webmock_states = []

  config.before(:context, :e2e) do
    E2eHelpers.configure!
    next unless defined?(WebMock)

    webmock = WebMock::Config.instance
    webmock_states.push([webmock.allow_net_connect, webmock.allow_localhost, webmock.allow])
    WebMock.allow_net_connect!
  end

  config.after(:context, :e2e) do
    next unless defined?(WebMock) && webmock_states.any?

    webmock = WebMock::Config.instance
    webmock.allow_net_connect, webmock.allow_localhost, webmock.allow = webmock_states.pop
  end
end
