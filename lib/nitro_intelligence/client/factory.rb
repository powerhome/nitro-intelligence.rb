require "nitro_intelligence/client/base"
require "nitro_intelligence/client/observed"
require "nitro_intelligence/client/observers/langfuse_observer"
require "nitro_intelligence/observability/project"

module NitroIntelligence
  module Client
    class Factory
      def initialize(observability_project_slug:, inference_max_retries: nil, inference_timeout: nil)
        @observability_project_slug = observability_project_slug
        @inference_max_retries = inference_max_retries
        @inference_timeout = inference_timeout
      end

      def build
        if @observability_project_slug.present?
          begin
            return Client::Observed.new(
              client: inference_client,
              observer: Client::Observers::LangfuseObserver.new(project_client: fetch_project_client)
            )
          rescue NitroIntelligence::Observability::ProjectClient::NotFoundError,
                 NitroIntelligence::Observability::Project::NotFoundError => e
            NitroIntelligence.logger.warn(
              "#{self.class} #{e} - Error raised initializing project - Falling back to base client (no observability)"
            )
          end
        end

        Client::Base.new(
          client: inference_client
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

      # The gateway owns failover between providers, and an upstream 429 it passes
      # on has already been decided there, so the SDK's own retries default to off
      # rather than to openai-ruby's two. A nil timeout keeps openai-ruby's default.
      def inference_client
        config = NitroIntelligence.config
        @inference_client ||= OpenAI::Client.new(
          api_key: config.inference_api_key,
          base_url: config.inference_base_url,
          max_retries: @inference_max_retries.nil? ? config.inference_max_retries : @inference_max_retries,
          **{ timeout: @inference_timeout || config.inference_timeout }.compact
        )
      end
    end
  end
end
