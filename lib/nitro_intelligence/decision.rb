module NitroIntelligence
  # What {Client::Base#decide} returns: a decision model's answers to the questions asked of it,
  # keyed by the names the questions were given. See https://docs.typesafe.ai/api/system-one.md
  class Decision
    # The answer to a `noul` question.
    #
    # @!attribute [r] noul
    #   @return [Float] the probability, from 0 to 1, that the answer is yes
    NoulAnswer = Data.define(:noul)

    # The answer to a `choice` question.
    #
    # @!attribute [r] choice
    #   @return [String] the most probable option's name
    # @!attribute [r] confidence
    #   @return [Float] how concentrated the probabilities are, from 0 to 1
    # @!attribute [r] probabilities
    #   @return [Hash{String => Float}] the probability of every option, keyed by option name
    ChoiceAnswer = Data.define(:choice, :confidence, :probabilities)

    # The answer to a `score` question, whose levels are numbered from 0 in the order the
    # question's `criteria` listed them.
    #
    # @!attribute [r] score
    #   @return [Float] the expected level, which may fall between levels
    # @!attribute [r] confidence
    #   @return [Float] how concentrated the probabilities are, from 0 to 1
    # @!attribute [r] probabilities
    #   @return [Hash{Integer, String => Float}] the probability of every level, keyed by level
    #     number, or by the key the gateway sent where that is not a number
    # @!attribute [r] legend
    #   @return [Hash{Integer, String => String, Hash}] the description of every level, as the
    #     question's `criteria` gave it, keyed like `probabilities`
    ScoreAnswer = Data.define(:score, :confidence, :probabilities, :legend)

    # @return [String, nil] the model that answered, as the gateway named it; nil when the
    #   response did not name one
    attr_reader :model
    # @return [ActiveSupport::HashWithIndifferentAccess] the answers keyed by question name, each a
    #   {NoulAnswer}, {ChoiceAnswer} or {ScoreAnswer}, or, for an answer of any other type, what the
    #   gateway sent
    attr_reader :answers
    # @return [Hash] the answers as the gateway sent them, keyed by question name
    attr_reader :raw_answers
    # @return [ActiveSupport::HashWithIndifferentAccess] the token counts the gateway reported
    attr_reader :usage
    # @api private
    attr_reader :response

    # @!method last_response
    #   @return [OpenAI::ResponseMetadata, nil] the HTTP response, including the
    #     gateway's headers
    delegate :last_response, to: :response

    # @api private
    def initialize(response)
      @response = response
      @model = response.model
      @raw_answers = response[:answers].to_h
      @answers = raw_answers.to_h { |name, answer| [name, build_answer(answer)] }.with_indifferent_access
      @usage = response[:usage].to_h.with_indifferent_access
    end

  private

    # A `box` answer, and any answer type added after this client, is returned as the hash it
    # arrived as rather than dropped. An answer that is not a hash at all is returned as it came
    # too, so it does not cost the caller every other answer in a response already paid for. Every
    # answer is built from a copy, so changing one leaves `raw_answers` as the gateway sent it.
    def build_answer(answer)
      answer = answer.deep_dup
      return answer unless answer.is_a?(Hash)

      case answer[:type]
      when "noul"
        NoulAnswer.new(noul: answer[:noul])
      when "choice"
        ChoiceAnswer.new(
          choice: answer[:choice],
          confidence: answer[:confidence],
          probabilities: answer[:probabilities].to_h.transform_keys(&:to_s)
        )
      when "score"
        ScoreAnswer.new(
          score: answer[:score],
          confidence: answer[:confidence],
          probabilities: levels(answer[:probabilities]),
          legend: levels(answer[:legend])
        )
      else
        answer
      end
    end

    # Levels arrive as JSON object keys, so "0", "1" and so on. A key that is not a number is
    # kept as it came rather than failing every other answer in the response.
    def levels(hash)
      hash.to_h.transform_keys do |level|
        Integer(level.to_s, 10)
      rescue ArgumentError
        level.to_s
      end
    end
  end
end
