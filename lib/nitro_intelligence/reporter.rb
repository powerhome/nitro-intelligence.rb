require "base64"
require "net/http"
require "uri"

module NitroIntelligence
  # Records evaluations of traces in Cerebro.
  #
  # @example
  #   reporter = NitroIntelligence::Reporter.new(observability_project_slug: "my-feature-project")
  #   reporter.score(name: "precision", value: 0.5, trace_id:)
  class Reporter
    # Raised by {#create_dataset_item} when Cerebro does not store the item. The message carries the
    # response's status and body.
    class DatasetItemError < StandardError; end

    # @param observability_project_slug [String] the Cerebro project the traces are recorded in
    # @raise [Observability::Project::NotFoundError] when `observability_projects` does not configure
    #   the project
    def initialize(observability_project_slug:)
      @observability_project_slug = observability_project_slug
      @project_client = fetch_project_client
      @host = NitroIntelligence.config.observability_base_url
    end

    # Adds an item to a dataset in the project, for evaluating prompts against later.
    #
    # @param attributes [Hash] the item, as Langfuse's `POST /api/public/dataset-items` takes it:
    #   `datasetName`, `input`, `expectedOutput`, `metadata`, `sourceTraceId` and the rest
    # @return [Net::HTTPSuccess] the response
    # @raise [DatasetItemError] when Cerebro does not store the item
    # @example
    #   reporter.create_dataset_item(datasetName: "sms-screening", input: { message: }, expectedOutput: "yes")
    def create_dataset_item(attributes)
      uri = URI("#{@host}/api/public/dataset-items")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Basic #{@project_client.project.auth_token}"
      request.body = attributes.to_json

      response = http.request(request)

      # Every other request in this gem raises on an unsuccessful response. Without this a
      # rejected write - bad credentials, a malformed item, a dataset that does not exist -
      # is indistinguishable from a successful one, and a caller building a dataset ends up
      # with a run against items that were never stored.
      unless response.is_a?(Net::HTTPSuccess)
        raise DatasetItemError, "#{response.code} creating dataset item: #{response.body}"
      end

      response
    end

    # Scores a trace. Scoring it again under the same `id` replaces the score.
    #
    # @param trace_id [String] the trace, such as {Trace.create_id} gives for a seed
    # @param name [String] what the score measures
    # @param value [Numeric, String, Boolean] the score: a number, `true` or `false` for `:boolean`,
    #   or the category's name for `:categorical`
    # @param id [String] identifies the score, so that recording it again replaces it. Defaults to
    #   one per trace and name.
    # @param data_type [Symbol] `:numeric`, `:boolean` or `:categorical`
    # @return [void]
    # @raise [ArgumentError] when `value` does not suit `data_type`
    def score(trace_id:, name:, value:, id: "#{trace_id}-#{name}", data_type: :numeric)
      @project_client.observability_client.create_score(
        id:,
        trace_id:,
        name:,
        value:,
        data_type:,
        environment: NitroIntelligence.environment
      )
    end

  private

    def fetch_project_client
      project_client = NitroIntelligence.project_client_registry.fetch(@observability_project_slug)
      if project_client.nil?
        raise NitroIntelligence::Observability::ProjectClient::NotFoundError,
              "No project session found for slug: #{@observability_project_slug}"
      end

      project_client
    end
  end
end
