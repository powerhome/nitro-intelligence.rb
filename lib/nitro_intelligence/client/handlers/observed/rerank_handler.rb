require "nitro_intelligence/client/handlers/observed/base_handler"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        # Recorded as a generation: Langfuse has no reranker observation type, and a generation
        # carries the model, usage and cost, as it does for decisions.
        #
        # @api private
        class RerankHandler < BaseHandler
          def create(query:, documents:, parameters: {})
            @base_handler.validate_and_resolve!(query, documents, parameters)

            trace_name = parameters[:trace_name] || project.slug

            @observer.observe(
              "rerank",
              type: :generation,
              parameters:,
              trace_name:,
              input: input(query, documents, parameters)
            ) do |generation|
              workflow(generation:, query:, documents:, parameters:)
            end
          end

        private

          # A caller whose trace already records the candidates, as a retrieval step of its own,
          # can pass `trace_documents: false` to record only how many there were.
          def input(query, documents, parameters)
            if parameters[:trace_documents] == false
              { query:, document_count: documents.size }
            else
              { query:, documents: }
            end
          end

          def workflow(generation:, query:, documents:, parameters:)
            ranking = @base_handler.perform_request(
              query:, documents:, parameters:, correlation_trace_id: generation.trace_id,
              mask_content: project.mask_content?
            )

            trace_attributes = {
              model: parameters[:model],
              output: ranking.results.map(&:to_h),
              usage_details: usage_details(ranking.meta),
              cost_details: @base_handler.cost_details(ranking),
            }

            [ranking, trace_attributes]
          end

          # Providers report a rerank's size as tokens, search units, or both. A count the provider
          # sent in some other shape is left out, rather than failing a request already paid for.
          def usage_details(meta)
            input_tokens = count(meta, :tokens, :input_tokens) || count(meta, :billed_units, :total_tokens)
            {
              prompt_tokens: input_tokens,
              total_tokens: input_tokens,
              search_units: count(meta, :billed_units, :search_units),
            }.compact.presence
          end

          def count(meta, section, key)
            value = meta[section][key] if meta[section].is_a?(Hash)
            value if value.is_a?(Numeric)
          end
        end
      end
    end
  end
end
