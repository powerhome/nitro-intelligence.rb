module NitroIntelligence
  module Observability
    # A project's connection to Cerebro, as {ProjectClientRegistry#fetch} gives it.
    class ProjectClient
      # Raised when there is no client for a project.
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
