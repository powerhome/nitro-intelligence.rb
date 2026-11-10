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

      # Wait for this project's observation exports queued or in flight when called.
      #
      # Observations completed later are excluded from this call's wait and result. The client
      # remains usable, and active observations are not ended. Queued scores and evaluator
      # results are not covered. Success does not guarantee immediate visibility in Cerebro.
      #
      # Earlier export failures are not reported, and discarded observations are not retried.
      # Concurrent calls have independent timeouts. Completed results take precedence over
      # timeout or shutdown.
      #
      # @param timeout [Numeric] maximum wait in seconds (default: 30). Exports continue after
      #   timeout. With zero, succeeds only for a running client with no pending exports.
      # @return [Boolean] true if this call's exports succeed or none are pending; false if
      #   exporting fails or cannot start, an observation being flushed is dropped, the wait
      #   times out, or shutdown interrupts pending work. Calls made while the client is
      #   stopping or stopped return false.
      # @example Export before submitting observation IDs for review
      #   client = NitroIntelligence.project_client_registry.fetch("my-feature-project")
      #   raise "Observation export failed or timed out" unless client.flush(timeout: 30)
      def flush(timeout: 30) # rubocop:disable Naming/PredicateMethod
        @observability_client.flush(timeout:) == OpenTelemetry::SDK::Trace::Export::SUCCESS
      end

      # @api private
      def shutdown
        @observability_client.shutdown
      end
    end
  end
end
