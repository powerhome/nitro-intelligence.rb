module NitroIntelligence
  # What {Client::Base#embed_query} and {Client::Base#embed_documents} return: one vector for each
  # input, in the order the inputs were given, however many requests it took to embed them.
  class Embeddings
    # @return [String, nil] the model that embedded the input, as the gateway named it
    attr_reader :model
    # @return [Array<Array<Float>>] one vector for each input, in input order
    attr_reader :vectors
    # @return [ActiveSupport::HashWithIndifferentAccess] `prompt_tokens` and `total_tokens`,
    #   summed over every request, each left out when a response did not report it
    attr_reader :usage
    # @return [Array<OpenAI::Models::CreateEmbeddingResponse>] the gateway's responses, one for each
    #   batch of input, each with its `last_response` and the gateway's headers
    attr_reader :responses

    # @api private
    def initialize(responses)
      @responses = responses
      @model = responses.first&.model
      @vectors = responses.flat_map { |response| response.data.sort_by(&:index).map(&:embedding) }
      @usage = %i[prompt_tokens total_tokens].index_with { |count| total(count) }.compact.with_indifferent_access
    end

    # The vector of the first input: the only one when the input was a single string.
    #
    # @return [Array<Float>, nil]
    def vector
      vectors.first
    end

  private

    # Left out when any response did not report it, rather than undercounting.
    def total(count)
      counts = responses.map { |response| response.usage&.public_send(count) }
      counts.sum if counts.any? && counts.none?(&:nil?)
    end
  end
end
