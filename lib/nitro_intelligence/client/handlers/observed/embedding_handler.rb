require "nitro_intelligence/client/handlers/observed/base_handler"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        # Recorded as one embedding observation per call, however many batches the input was sent
        # in, so an index rebuild is one observation rather than one for each entry.
        #
        # @api private
        class EmbeddingHandler < BaseHandler
          OBSERVATION_NAMES = { query: "embed-query", document: "embed-documents" }.freeze

          def create(input:, input_type:, parameters: {})
            @base_handler.validate_and_resolve!(input, input_type, parameters)

            trace_name = parameters[:trace_name] || project.slug
            texts = @base_handler.texts(input, input_type, parameters)

            # The texts as the model received them, prefix included, since the prefix changes the
            # vector as much as the text does.
            @observer.observe(
              OBSERVATION_NAMES.fetch(input_type),
              type: :embedding,
              parameters:,
              trace_name:,
              input: input.is_a?(Array) ? texts : texts.first
            ) do |embedding|
              workflow(embedding:, input:, input_type:, parameters:)
            end
          end

        private

          def workflow(embedding:, input:, input_type:, parameters:)
            responses = []
            embeddings = @base_handler.perform_request(
              input:, input_type:, parameters:,
              correlation_trace_id: embedding.trace_id, mask_content: project.mask_content?, responses:
            )

            # The vectors are never recorded: they are large, mean nothing to read, and are the
            # caller's to store. Their count and size say whether the call did what was asked.
            trace_attributes = {
              model: embeddings.model,
              output: { count: embeddings.vectors.size, dimensions: embeddings.vector&.size },
              usage_details: usage_details(embeddings.usage),
              cost_details: @base_handler.cost_details(embeddings),
            }

            [embeddings, trace_attributes]
          rescue
            record_billed_batches(embedding, responses)
            raise
          end

          # A batch that fails after others succeeded leaves those billed, so the failed call still
          # records what they used and cost, rather than nothing, before the error is raised.
          def record_billed_batches(embedding, responses)
            return if responses.empty?

            billed = Embeddings.new(responses)
            attributes = {
              usage_details: usage_details(billed.usage),
              cost_details: @base_handler.cost_details(billed),
            }.compact
            embedding.update(attributes) if attributes.any?
          end

          # Recorded under Langfuse's own `input` and `total` keys. OpenAI's names are only recognised
          # alongside `completion_tokens`, which an embedding has none of, so Langfuse would otherwise
          # keep `prompt_tokens` and `total_tokens` as two counters and total them, doubling the count.
          def usage_details(usage)
            { input: usage[:prompt_tokens], total: usage[:total_tokens] }.compact.presence
          end
        end
      end
    end
  end
end
