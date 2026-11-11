# End-to-end specs: the real client against a real inference gateway, with nothing stubbed. They
# make billable model calls, so they run only through `rake e2e` (see the Rakefile), never in the
# default suite, and need a gateway key in NIP_E2E_INFERENCE_API_KEY.
#
# Assertions check what any working model must get right, not exact wording, so that a model
# upgrade behind the gateway does not fail them while a broken request or response contract does.
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

  def self.configure!
    api_key = ENV.fetch(API_KEY_VARIABLE, "")
    if api_key.empty?
      raise "#{API_KEY_VARIABLE} is not set. The end-to-end specs call the real inference gateway " \
            "and need a key for it."
    end

    NitroIntelligence.configure do |config|
      config.logger = Logger.new(nil)
      config.inference_api_key = api_key
      config.inference_base_url = ENV[BASE_URL_VARIABLE] if ENV[BASE_URL_VARIABLE].present?
      config.model_config = MODEL_CONFIG
    end
  end

  OBSERVABILITY_PROJECT_SLUG = "ruby-sdk-e2e".freeze
  OBSERVABILITY_VARIABLES = {
    "id" => "NIP_E2E_OBSERVABILITY_PROJECT_ID",
    "public_key" => "NIP_E2E_OBSERVABILITY_PUBLIC_KEY",
    "secret_key" => "NIP_E2E_OBSERVABILITY_SECRET_KEY",
  }.freeze

  # The "Ruby SDK End-to-End Tests" Cerebro project, which powerhome/software provisions along
  # with these credentials. Only the tracing specs need it, so only they call this.
  def self.configure_observability!
    credentials = OBSERVABILITY_VARIABLES.transform_values { ENV.fetch(_1, "") }
    missing = OBSERVABILITY_VARIABLES.values_at(*credentials.select { |_, value| value.empty? }.keys)
    if missing.any?
      raise "#{missing.join(', ')} not set. The tracing specs record to a real Cerebro project " \
            "and need its credentials."
    end

    NitroIntelligence.configure do |config|
      config.observability_projects = [credentials.merge("slug" => OBSERVABILITY_PROJECT_SLUG)]
    end
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

RSpec.configure do |config|
  config.include E2eHelpers, :e2e

  config.before(:context, :e2e) do
    E2eHelpers.configure!
    # Other specs loaded in the same process load webmock/rspec, which blocks real requests.
    WebMock.allow_net_connect! if defined?(WebMock)
  end

  config.after(:context, :e2e) do
    WebMock.disable_net_connect! if defined?(WebMock)
  end
end
