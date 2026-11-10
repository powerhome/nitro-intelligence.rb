module NitroIntelligence
  # What {Client::Base#rerank} returns: the documents' relevance to the query, most relevant first.
  class Ranking
    # One document's place in the ranking.
    #
    # @!attribute [r] index
    #   @return [Integer] the document's position in the `documents` given to {Client::Base#rerank}
    # @!attribute [r] relevance_score
    #   @return [Float, nil] how relevant the document is to the query, from 0 to 1, or nil when the
    #     provider sent no score, which ranks the document last
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
        Result.new(index: result[:index], relevance_score: Float(result[:relevance_score], exception: false))
      end
      # Ties keep the order the provider gave them, since sort_by alone is not stable.
      @results = @results.each_with_index.sort_by do |result, index|
        [-(result.relevance_score || -Float::INFINITY), index]
      end.map(&:first)
      @meta = response[:meta].to_h.deep_dup.with_indifferent_access
    end
  end
end
