module NitroIntelligence
  module Observability
    class ProjectClient
      class NotFoundError < StandardError; end

      attr_reader :project, :observability_client

      def initialize(project:, observability_client:)
        @project = project
        @observability_client = observability_client
      end

      def shutdown
        @observability_client.shutdown
      end
    end
  end
end
