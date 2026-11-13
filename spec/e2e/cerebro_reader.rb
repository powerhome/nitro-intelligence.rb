require "erb"
require "json"
require "net/http"

# Reads back what the client recorded in the end-to-end Cerebro project, through Langfuse's public
# API. Cerebro runs Langfuse v4 with event-only reads, where the trace endpoints are gone: a trace is
# read as its observations, from Observations API v2, and its scores from Scores API v3.
class CerebroReader
  # Cerebro ingests exported observations and scores asynchronously, so a flushed one can take a
  # while to become readable.
  TIMEOUT = 300
  POLL_INTERVAL = 3
  # Observations API v2 requires a start-time window. The trace ID already isolates a run's
  # observations, so the window only has to absorb clock skew between the runner and Cerebro.
  CLOCK_SKEW_MARGIN = 600
  OBSERVATION_FIELDS = "core,basic,time,io,metadata,model,usage,prompt,metrics,trace_context".freeze
  SCORE_FIELDS = "core,details,subject".freeze

  # A rate limit or server error, which a poll retries.
  class TransientError < StandardError; end
  class NotFoundError < StandardError; end

  # Observations API v2 returns input and output as the raw strings Cerebro stored, JSON or not.
  def self.parse(value)
    JSON.parse(value)
  rescue JSON::ParserError, TypeError
    value
  end

  def initialize(project)
    @project = project
  end

  # The trace's observations, once the block accepts them.
  def observations(trace_id, &)
    poll("observations of trace #{trace_id}", ready: ->(data) { data.any? && yield(data) }) do
      get(
        "/api/public/v2/observations",
        traceId: trace_id, fields: OBSERVATION_FIELDS, limit: 100,
        fromStartTime: (Time.now - CLOCK_SKEW_MARGIN).utc.iso8601,
        toStartTime: (Time.now + CLOCK_SKEW_MARGIN).utc.iso8601
      ).fetch("data")
    end
  end

  # The trace's scores, once the block accepts them.
  def scores(trace_id, &)
    poll("scores of trace #{trace_id}", ready: ->(data) { data.any? && yield(data) }) do
      get("/api/public/v3/scores", traceId: trace_id, fields: SCORE_FIELDS).fetch("data")
    end
  end

  # The prompt at the label, or nil when there is none.
  def prompt(name, label:)
    get("/api/public/v2/prompts/#{ERB::Util.url_encode(name)}", label:)
  rescue NotFoundError
    nil
  end

  def create_prompt(attributes)
    request = Net::HTTP::Post.new(uri("/api/public/v2/prompts"), "Content-Type" => "application/json")
    request.body = JSON.generate(attributes)
    perform(request)
  end

private

  def poll(description, ready:)
    deadline = Time.now + TIMEOUT
    last_seen = "nothing yet"

    loop do
      begin
        data = yield
        return data if ready.call(data)

        last_seen = JSON.pretty_generate(data)
      rescue TransientError => e
        last_seen = e.message
      end
      raise "Cerebro had no complete #{description} after #{TIMEOUT}s. Last seen: #{last_seen}" if Time.now > deadline

      sleep POLL_INTERVAL
    end
  end

  def get(path, **query)
    perform(Net::HTTP::Get.new(uri(path, query)))
  end

  def uri(path, query = {})
    URI.join(NitroIntelligence.config.observability_base_url, path).tap do |uri|
      uri.query = URI.encode_www_form(query) if query.any?
    end
  end

  # Any other client error means the request itself is wrong, as a retired endpoint's 404 is, so it
  # fails at once rather than being mistaken for data not ingested yet.
  def perform(request)
    request["Authorization"] = "Basic #{@project.auth_token}"
    response = Net::HTTP.start(request.uri.host, request.uri.port, use_ssl: request.uri.scheme == "https") do |http|
      http.request(request)
    end

    case response
    when Net::HTTPSuccess then JSON.parse(response.body)
    when Net::HTTPNotFound then raise NotFoundError, "#{request.path}: #{response.body}"
    when Net::HTTPTooManyRequests, Net::HTTPServerError
      raise TransientError, "Cerebro answered #{response.code}: #{response.body}"
    else raise "Cerebro answered #{request.method} #{request.path} with #{response.code}: #{response.body}"
    end
  end
end
