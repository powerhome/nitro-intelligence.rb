require "openai"
require "nitro_intelligence/client/handlers/base_handler"
require "nitro_intelligence/embeddings"

module NitroIntelligence
  module Client
    module Handlers
      # Embeds text over the gateway's `/v1/embeddings` route, splitting a long list of inputs into
      # batches of `batch_size` so an index rebuild of thousands of entries is one call.
      #
      # @api private
      class EmbeddingHandler < BaseHandler
        # Fields of openai-ruby's embedding request taken from `parameters`. The input is the
        # handler's own argument, and the vectors are always requested as floats, the only
        # encoding openai-ruby decodes into the response it returns.
        ALLOWED_EXTRA_PARAMETERS =
          (OpenAI::Models::EmbeddingCreateParams.fields.keys - %i[input encoding_format]).uniq.freeze

        DEFAULT_BATCH_SIZE = 128

        # How Qwen3-Embedding expects a query to carry its task. Documents are embedded without one.
        # See https://huggingface.co/Qwen/Qwen3-Embedding-0.6B
        INSTRUCTION_FORMAT = "Instruct: %<instruction>s\nQuery:%<text>s".freeze

        def create(input:, parameters: {})
          validate_and_resolve!(input, parameters)
          perform_request(input:, parameters:)
        end

        def perform_request(input:, parameters: {}, correlation_trace_id: nil, mask_content: false)
          add_gateway_headers(parameters, correlation_trace_id:, mask_content:)
          responses = texts(input, parameters).each_slice(parameters[:batch_size]).map do |batch|
            @client.embeddings.create(
              input: batch, encoding_format: :float, **parameters.slice(*ALLOWED_EXTRA_PARAMETERS)
            )
          end
          Embeddings.new(responses)
        end

        def validate_and_resolve!(input, parameters)
          default_parameters = {
            metadata: {},
            model: NitroIntelligence.model_catalog.default_embedding_model&.name,
            batch_size: DEFAULT_BATCH_SIZE,
          }

          parameters.replace(default_parameters.merge(parameters))
          Client.validate_model(parameters[:model], type: EmbeddingModel)
          validate_input!(input)
          validate_batch_size!(parameters[:batch_size])
        end

        # The texts as the model receives them: each prefixed with the instruction, when there is one.
        def texts(input, parameters)
          instruction = parameters[:instruction].presence
          Array(input).map do |text|
            instruction ? format(INSTRUCTION_FORMAT, instruction:, text:) : text
          end
        end

        # The cost of every batch, added up. A batch the gateway did not price leaves the whole call
        # unpriced, because a sum that silently skips it would understate the spend.
        def cost_details(embeddings)
          costs = embeddings.responses.map { |response| super(response) }
          return nil if costs.empty? || costs.any?(&:nil?)

          %i[total input output].index_with do |component|
            costs.sum { |cost| cost[component] } if costs.all? { |cost| cost.key?(component) }
          end.compact
        end

      private

        # Checked before any batch is sent, so a bad entry late in a long list cannot fail the call
        # after the batches before it were billed.
        def validate_input!(input)
          texts = Array(input)
          return if texts.any? && texts.all? { |text| text.is_a?(String) && text.present? }

          raise ArgumentError, "input must be a non-empty string or a non-empty array of non-empty strings"
        end

        def validate_batch_size!(batch_size)
          return if batch_size.is_a?(Integer) && batch_size.positive?

          raise ArgumentError, "batch_size must be a positive integer, not #{batch_size.inspect}"
        end
      end
    end
  end
end
