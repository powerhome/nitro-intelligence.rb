require "json"
require "net/http"
require "securerandom"
require_relative "e2e_helper"

RSpec.describe "Cerebro tracing, end to end", :e2e do
  subject(:client) do
    NitroIntelligence::Client.new(observability_project_slug: E2eHelpers::OBSERVABILITY_PROJECT_SLUG,
                                  inference_timeout: 120)
  end

  # Cerebro ingests exported observations asynchronously, so a flushed one can take a while to
  # become readable.
  let(:ingestion_timeout) { 300 }
  let(:project_client) { NitroIntelligence.project_client_registry.fetch(E2eHelpers::OBSERVABILITY_PROJECT_SLUG) }
  # A fresh seed per run, so the trace read back can only be this run's.
  let(:trace_seed) { "nitro-intelligence.rb-e2e-#{SecureRandom.uuid}" }
  let(:trace_name) { "nitro-intelligence.rb e2e" }

  before(:context) { E2eHelpers.configure_observability! }

  # The start-time window Observations API v2 requires. The seed already isolates this run's trace,
  # so the window only has to be wide enough to absorb clock skew between the runner and Cerebro.
  let(:clock_skew_margin) { 600 }

  # Cerebro runs Langfuse v4 with event-only reads, where the trace endpoints are gone: a trace is
  # read as its observations, from Observations API v2. Returns the response, which a caller
  # retries on a rate limit or server error.
  def get_observations(trace_id, from:)
    uri = URI.join(NitroIntelligence.config.observability_base_url, "/api/public/v2/observations")
    uri.query = URI.encode_www_form(
      traceId: trace_id, fields: "core,basic,model,usage,trace_context",
      fromStartTime: from.utc.iso8601, toStartTime: (Time.now + clock_skew_margin).utc.iso8601
    )
    Net::HTTP.get_response(uri, "Authorization" => "Basic #{project_client.project.auth_token}")
  end

  # Any other client error means the request itself is wrong, as a retired endpoint's 404 is, so it
  # fails at once rather than being mistaken for an observation not ingested yet.
  def transient?(response)
    response.is_a?(Net::HTTPTooManyRequests) || response.is_a?(Net::HTTPServerError)
  end

  def fetch_observations(trace_id, from:)
    deadline = Time.now + ingestion_timeout
    last_status = "no response yet"

    loop do
      response = get_observations(trace_id, from:)
      if response.is_a?(Net::HTTPSuccess)
        observations = JSON.parse(response.body).fetch("data")
        return observations if observations.any? { _1["type"] == "GENERATION" }

        last_status = "no generation yet"
      elsif transient?(response)
        last_status = "Cerebro answered #{response.code}"
      else
        raise "Cerebro answered #{response.code}: #{response.body}"
      end
      if Time.now > deadline
        raise "Trace #{trace_id} had no generation in Cerebro after #{ingestion_timeout}s (#{last_status})"
      end

      sleep 5
    end
  end

  it "records a chat completion with the gateway's cost" do
    requested_at = Time.now - clock_skew_margin
    response = client.chat(
      message: "Reply with the single word pong and nothing else.",
      parameters: { max_tokens: 1000, trace_seed:, trace_name:, metadata: e2e_metadata }
    )
    expect(project_client.flush(timeout: 30)).to be(true)

    observations = fetch_observations(NitroIntelligence::Trace.create_id(seed: trace_seed), from: requested_at)
    generation = observations.find { _1["type"] == "GENERATION" }

    expect(generation).to include("traceName" => trace_name, "model" => E2eHelpers::TEXT_MODEL)
    expect(generation.dig("costDetails", "total")).to be_within(1e-9).of(
      Float(response.last_response.headers["x-litellm-response-cost"])
    )
  end
end
