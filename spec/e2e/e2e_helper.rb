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
require "tempfile"
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
  # Configured here but served by no deployment, for a request the gateway refuses without reaching
  # a model.
  UNKNOWN_MODEL = "nitro-intelligence.rb/e2e-no-such-model".freeze

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
      { "name" => UNKNOWN_MODEL, "type" => "text" },
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

  # Exports the observations the client has recorded so far, so Cerebro can ingest them. Scores are
  # not covered: they go out on the client's own timer. A failed export fails here rather than as a
  # read that never finds them.
  def flush_observations
    [OBSERVABILITY_PROJECT_SLUG, MASKED_OBSERVABILITY_PROJECT_SLUG].each do |slug|
      next if NitroIntelligence.project_client_registry.fetch(slug).flush(timeout: 30)

      raise "Exporting the #{slug} project's observations to Cerebro failed or timed out"
    end
  end

  # A trace of the spec's own, so whatever is read back can only be this run's.
  def new_trace_seed
    "nitro-intelligence.rb-e2e-#{SecureRandom.uuid}"
  end

  # Spend logs on the gateway carry this, so the suite's cost can be told apart from real usage.
  def e2e_metadata
    { source: "nitro-intelligence.rb e2e", github_run_id: ENV.fetch("GITHUB_RUN_ID", "local") }
  end
end

# What the specs send and how they judge what comes back.
module E2eContent
  def cosine_similarity(left, right)
    dot = left.zip(right).sum { |a, b| a * b }
    dot / (Math.sqrt(left.sum { _1**2 }) * Math.sqrt(right.sum { _1**2 }))
  end

  def words(text)
    text.downcase.scan(/[a-z]+/)
  end

  # A PNG drawn with ImageMagick, as a byte string: a shape of one color on white.
  def drawn_image(draw, fill:)
    Tempfile.create(["drawn", ".png"]) do |file|
      MiniMagick::Tool::Convert.new do |convert|
        convert.size("256x256").xc("white").fill(fill).draw(draw)
        convert << file.path
      end
      File.binread(file.path)
    end
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

  # A completion's usage and cost, recorded as the response and the gateway reported them.
  def expect_accounted(observation, response)
    expect_usage(observation, total: response.usage.total_tokens)
    expect_cost(observation, gateway_cost(response))
  end

  # The gateway's charge, recorded exactly. Some models are free, so it may be zero, but it is never
  # missing.
  def expect_cost(observation, cost)
    expect(observation.dig("costDetails", "total")).to be_within(1e-9).of(cost)
    expect(observation["totalCost"]).to be_within(1e-9).of(cost)
  end

  # Cerebro stores metadata values that read as JSON, such as a run ID's digits, as what they parse
  # to, though the client sends them as strings.
  def expect_metadata(observation, expected)
    expected = expected.stringify_keys
    recorded = observation.fetch("metadata").slice(*expected.keys).transform_values(&:to_s)
    expect(recorded).to eq(expected.transform_values(&:to_s))
  end
end

# A request recorded as a trace of its own, checked end to end: grouped and named as the request asked,
# and read back once Cerebro has it.
RSpec.shared_context "with a traced request" do
  subject(:client) do
    NitroIntelligence::Client.new(observability_project_slug: E2eHelpers::OBSERVABILITY_PROJECT_SLUG,
                                  inference_timeout: 120)
  end

  let(:masked_client) do
    NitroIntelligence::Client.new(observability_project_slug: E2eHelpers::MASKED_OBSERVABILITY_PROJECT_SLUG,
                                  inference_timeout: 120)
  end
  let(:trace_seed) { new_trace_seed }
  let(:trace_id) { NitroIntelligence::Trace.create_id(seed: trace_seed) }
  let(:trace_name) { "nitro-intelligence.rb e2e: #{RSpec.current_example.description}" }
  let(:user_id) { "nitro-intelligence.rb-e2e" }
  let(:session_id) { "nitro-intelligence.rb-e2e-#{ENV.fetch('GITHUB_RUN_ID', 'local')}" }
  let(:tags) { %w[e2e nitro-intelligence.rb] }
  let(:trace_parameters) { { trace_seed:, trace_name:, user_id:, session_id:, tags:, metadata: e2e_metadata } }

  # Reads back the trace once each named observation has finished and been priced or, for a failed
  # request, marked as failed.
  def recorded_trace(*names)
    flush_observations
    cerebro.observations(trace_id) do |observations|
      names.all? do |name|
        observation = observations.find { _1["name"] == name }
        observation && observation["endTime"] &&
          (observation.dig("costDetails", "total") || observation["level"] == "ERROR")
      end
    end
  end

  def recorded_request(name)
    observation_named(recorded_trace(name), name)
  end

  def expect_request(observation, name:, type: "GENERATION")
    expect(observation).to include(
      "name" => name, "type" => type, "traceId" => trace_id, "parentObservationId" => nil, "level" => "DEFAULT",
      "environment" => NitroIntelligence.environment, "traceName" => trace_name, "userId" => user_id,
      "sessionId" => session_id
    )
    expect(observation["tags"]).to match_array(tags)
    expect_metadata(observation, e2e_metadata)
  end

  # A masked project records the request, its usage and cost, but none of its content.
  def expect_masked(observation)
    expect(CerebroReader.parse(observation["input"])).to eq("[masked]") if observation["input"].present?
    expect(CerebroReader.parse(observation["output"])).to eq("[masked]")
    expect(observation.to_s).not_to include("@@@langfuseMedia")
  end
end

RSpec.configure do |config|
  config.include E2eHelpers, :e2e
  config.include E2eExpectations, :e2e
  config.include E2eContent, :e2e
  # Each example checks a whole feature, so a failure reports every part that is wrong, not just the first.
  config.define_derived_metadata(:e2e) { |metadata| metadata[:aggregate_failures] = true }

  # Other specs loaded in the same process load webmock/rspec, which blocks real requests. The e2e
  # groups lift that and put back whatever was in force before, allowances included.
  webmock_states = []
  # Every setting `WebMock.allow_net_connect!` overwrites.
  webmock_settings = %i[allow_net_connect allow_localhost allow net_http_connect_on_start]

  config.before(:context, :e2e) do
    # A description, location or ID filter overrides spec_helper's exclusion, so a run that mixes in
    # other specs could otherwise reach these. They run only when e2e files alone are named, or with
    # `--tag e2e`.
    unless E2E_ONLY || RSpec.configuration.inclusion_filter[:e2e]
      skip "End-to-end specs make billable calls: name only e2e files, or pass --tag e2e"
    end

    E2eHelpers.configure!
    next unless defined?(WebMock)

    webmock = WebMock::Config.instance
    webmock_states.push(webmock_settings.map { webmock.public_send(_1) })
    WebMock.allow_net_connect!
  end

  config.after(:context, :e2e) do
    next unless defined?(WebMock) && webmock_states.any?

    webmock = WebMock::Config.instance
    webmock_settings.zip(webmock_states.pop).each { |setting, value| webmock.public_send(:"#{setting}=", value) }
  end
end
