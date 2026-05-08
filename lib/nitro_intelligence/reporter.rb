require "base64"
require "net/http"
require "uri"

module NitroIntelligence
  class Reporter
    def initialize(observability_project_slug:)
      @observability_project_slug = observability_project_slug
      @project_client = fetch_project_client
      @host = NitroIntelligence.config.observability_base_url
    end

    def create_dataset_item(attributes)
      uri = URI("#{@host}/api/public/dataset-items")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Basic #{@project_client.project.auth_token}"
      request.body = attributes.to_json

      http.request(request)
    end

    def score(trace_id:, name:, value:, id: "#{trace_id}-#{name}")
      @project_client.observability_client.create_score(
        id:,
        trace_id:,
        name:,
        value:,
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
