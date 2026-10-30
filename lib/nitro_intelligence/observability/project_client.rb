module NitroIntelligence
  module Observability
    # A project's connection to Cerebro, as {ProjectClientRegistry#fetch} gives it.
    class ProjectClient
      # Not raised by the gem, which raises {Project::NotFoundError} for a project
      # `observability_projects` does not configure. Public only because applications raise it
      # themselves.
      class NotFoundError < StandardError; end

      # @return [Project]
      attr_reader :project
      # @api private
      attr_reader :observability_client

      # @api private
      def initialize(project:, observability_client:)
        @project = project
        @observability_client = observability_client
      end

      # @api private
      def shutdown
        @observability_client.shutdown
      end
    end
  end
end
