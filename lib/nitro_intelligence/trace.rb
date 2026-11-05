module NitroIntelligence
  # Trace IDs, for correlating an observed request with what else a host records about it.
  module Trace
    # The ID of the trace a request passing `trace_seed: seed` is recorded under. The same seed
    # always gives the same ID.
    #
    # @param seed [String] the request's `trace_seed`, such as a document's ID
    # @return [String] the trace ID
    # @example
    #   NitroIntelligence::Trace.create_id(seed: "document-123")
    def self.create_id(seed:)
      Langfuse::TraceId.create(seed:)
    end
  end
end
