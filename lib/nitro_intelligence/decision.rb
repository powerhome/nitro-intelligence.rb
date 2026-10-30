module NitroIntelligence
  # A decision model's answers to the questions asked of it, keyed by the names the questions
  # were given. See https://docs.typesafe.ai/api/system-one.md
  class Decision
    # The probability, from 0 to 1, that the answer is yes.
    NoulAnswer = Data.define(:noul)

    # The most probable option, how concentrated the probabilities are, and the probability
    # of every option, keyed by option name.
    ChoiceAnswer = Data.define(:choice, :confidence, :probabilities)

    # The expected level, which may fall between levels, how concentrated the probabilities
    # are, and the probability and description of every level, keyed by level number.
    ScoreAnswer = Data.define(:score, :confidence, :probabilities, :legend)

    # `raw_answers` are the answers as the gateway returned them, for recording.
    attr_reader :model, :answers, :raw_answers, :usage, :response

    delegate :last_response, to: :response

    def initialize(response)
      @response = response
      @model = response.model
      @raw_answers = response[:answers].to_h
      @answers = raw_answers.to_h { |name, answer| [name, build_answer(answer)] }.with_indifferent_access
      @usage = response[:usage].to_h
    end

  private

    # A `box` answer, and any answer type added after this client, is returned as the hash it
    # arrived as rather than dropped.
    def build_answer(answer)
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
        Integer(level.to_s)
      rescue ArgumentError
        level.to_s
      end
    end
  end
end
