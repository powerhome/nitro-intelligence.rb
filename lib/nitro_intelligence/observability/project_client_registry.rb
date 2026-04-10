require "nitro_intelligence/langfuse_extension"
require "nitro_intelligence/observability/project"
require "nitro_intelligence/observability/project_client"

module NitroIntelligence
  module Observability
    class ProjectClientRegistry
      def initialize(base_url:)
        @base_url = base_url
        @project_clients = {}
      end

      def fetch(slug)
        @project_clients[slug] ||= build_project_client(slug)
      end

      def shutdown_all
        @project_clients.values.each(&:shutdown)
      end

    private

      def build_project_client(slug)
        project = Observability::Project.find_by_slug(slug:)

        unless project
          raise NitroIntelligence::Observability::Project::NotFoundError,
                "No observability project config found for slug: #{slug}"
        end

        observability_client = NitroIntelligence::LangfuseExtension.new do |config|
          config.public_key = project.public_key
          config.secret_key = project.secret_key
          config.base_url = @base_url
          # Default flush of 60 seconds can be too quick when
          # dealing with longer responses like image gen
          config.flush_interval = 120
        end

        Observability::ProjectClient.new(project:, observability_client:)
      end
    end
  end
end
