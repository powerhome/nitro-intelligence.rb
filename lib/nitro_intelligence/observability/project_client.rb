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

      # Wait for this project's observation exports that are queued or in flight when the call starts.
      #
      # Captures the queued observations and current export together under the queue lock,
      # wakes the worker and waits for that work only. Observations completed later are
      # excluded from its wait and result, and active observations are not ended.
      # Reports failed exports or dropped observations within the captured work; concurrent
      # callers covering the same failed export all receive false. Earlier failures are not
      # retained, and discarded observations are not retried. A timeout leaves exports running
      # and the client usable. Returns false if shutdown starts or the client is stopped.
      # Queued scores, Cerebro ingestion and evaluator results are not included.
      #
      # @param timeout [Numeric] maximum time in seconds to wait, including in-flight exports
      #   and concurrent flushes; reaching it does not cancel an export
      # @return [Boolean] true if the exports this call waits for succeed (including an empty
      #   buffer), false for a captured export failure or dropped observation, timeout or shutdown
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
