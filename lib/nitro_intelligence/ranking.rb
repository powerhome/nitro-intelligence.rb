module NitroIntelligence
  # What {Client::Base#rerank} returns: the documents' relevance to the query, most relevant first.
  class Ranking
    # One document's place in the ranking.
    #
    # @!attribute [r] index
    #   @return [Integer] the document's position in the `documents` given to {Client::Base#rerank}
    # @!attribute [r] relevance_score
    #   @return [Float] how relevant the document is to the query, from 0 to 1
    Result = Data.define(:index, :relevance_score)

    # @return [String, nil] the gateway's identifier for the request
    attr_reader :id
    # @return [Array<Result>] the documents ranked, most relevant first, limited to `top_n` when
    #   that was given
    attr_reader :results
    # @return [ActiveSupport::HashWithIndifferentAccess] what the gateway reported as billed:
    #   `tokens` (`input_tokens`) and `billed_units` (`search_units`, `total_tokens`), each where the
    #   provider sent them
    attr_reader :meta
    # @api private
    attr_reader :response

    # @!method last_response
    #   @return [OpenAI::ResponseMetadata, nil] the HTTP response, including the
    #     gateway's headers
    delegate :last_response, to: :response

    # @api private
    def initialize(response)
      @response = response
      @id = response[:id]
      @results = response[:results].to_a.map do |result|
        Result.new(index: result[:index], relevance_score: result[:relevance_score])
      end
      @results = @results.sort_by { |result| -result.relevance_score.to_f }
      @meta = response[:meta].to_h.deep_dup.with_indifferent_access
    end
  end
end
