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
          def create(input:, parameters: {})
            @base_handler.validate_and_resolve!(input, parameters)

            trace_name = parameters[:trace_name] || project.slug
            texts = @base_handler.texts(input, parameters)

            # The texts as the model received them, instruction included, since the instruction
            # changes the vector as much as the text does.
            @observer.observe(
              "embedding",
              type: :embedding,
              parameters:,
              trace_name:,
              input: input.is_a?(Array) ? texts : texts.first
            ) do |embedding|
              workflow(embedding:, input:, parameters:)
            end
          end

        private

          def workflow(embedding:, input:, parameters:)
            embeddings = @base_handler.perform_request(
              input:, parameters:, correlation_trace_id: embedding.trace_id, mask_content: project.mask_content?
            )

            # The vectors are never recorded: they are large, mean nothing to read, and are the
            # caller's to store. Their count and size say whether the call did what was asked.
            trace_attributes = {
              model: embeddings.model,
              output: { count: embeddings.vectors.size, dimensions: embeddings.vector&.size },
              usage_details: embeddings.usage.to_h.symbolize_keys.presence,
              cost_details: @base_handler.cost_details(embeddings),
            }

            [embeddings, trace_attributes]
          end
        end
      end
    end
  end
end
