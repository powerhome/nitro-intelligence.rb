require "json"
require "net/http"
require "securerandom"
require_relative "e2e_helper"

RSpec.describe "Cerebro tracing, end to end", :e2e do
  subject(:client) do
    NitroIntelligence::Client.new(observability_project_slug: E2eHelpers::OBSERVABILITY_PROJECT_SLUG,
                                  inference_timeout: 120)
  end

  # Cerebro ingests exported observations asynchronously, so a flushed trace can take a while to
  # become readable.
  let(:ingestion_timeout) { 300 }
  let(:project_client) { NitroIntelligence.project_client_registry.fetch(E2eHelpers::OBSERVABILITY_PROJECT_SLUG) }
  # A fresh seed per run, so the trace read back can only be this run's.
  let(:trace_seed) { "nitro-intelligence.rb-e2e-#{SecureRandom.uuid}" }
  let(:trace_name) { "nitro-intelligence.rb e2e" }

  before(:context) { E2eHelpers.configure_observability! }

  def cerebro_get(path, query = {})
    uri = URI.join(NitroIntelligence.config.observability_base_url, path)
    uri.query = URI.encode_www_form(query) if query.any?
    Net::HTTP.get_response(uri, "Authorization" => "Basic #{project_client.project.auth_token}")
  end

  def fetch_trace(trace_id, since:)
    deadline = Time.now + ingestion_timeout

    loop do
      response = cerebro_get("/api/public/traces/#{trace_id}")
      return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)
      raise "Cerebro answered #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPNotFound)

      if Time.now > deadline
        raise "Trace #{trace_id} did not appear in Cerebro within #{ingestion_timeout}s. " \
              "Traces in the project since the request: #{recent_traces(since)}"
      end

      sleep 5
    end
  end

  # Tells a trace recorded under another ID apart from nothing reaching Cerebro at all.
  def recent_traces(since)
    response = cerebro_get("/api/public/traces", fromTimestamp: since.utc.iso8601, limit: 10)
    return "listing failed with #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    traces = JSON.parse(response.body).fetch("data")
    traces.empty? ? "none" : traces.map { "#{_1['id']} (#{_1['name']})" }.join(", ")
  end

  it "records a chat completion with the gateway's cost" do
    requested_at = Time.now - 60
    response = client.chat(
      message: "Reply with the single word pong and nothing else.",
      parameters: { max_tokens: 1000, trace_seed:, trace_name:, metadata: e2e_metadata }
    )
    expect(project_client.flush(timeout: 30)).to be(true)

    trace = fetch_trace(NitroIntelligence::Trace.create_id(seed: trace_seed), since: requested_at)
    generation = trace.fetch("observations").find { _1["type"] == "GENERATION" }

    expect(trace["name"]).to eq(trace_name)
    expect(generation).to include("model" => E2eHelpers::TEXT_MODEL)
    expect(generation.dig("costDetails", "total")).to be_within(1e-9).of(
      Float(response.last_response.headers["x-litellm-response-cost"])
    )
  end
end
