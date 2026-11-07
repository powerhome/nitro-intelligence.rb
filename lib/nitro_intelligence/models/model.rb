module NitroIntelligence
  # @api private
  class Model
    # What the model is for, as an error names it: "image" for ImageModel, "text-to-speech" for
    # TextToSpeechModel. Taken from the class name, so a new kind of model has one without
    # declaring it.
    def self.kind = name.demodulize.delete_suffix("Model").underscore.dasherize

    attr_reader :name, :omit_output_fields

    def initialize(name:, omit_output_fields: [], **)
      @name = name
      @omit_output_fields = omit_output_fields.map { |field| field.split(".").map(&:to_sym) }
    end
  end

  # @api private
  class ImageModel < Model
    attr_reader :aspect_ratios, :resolutions

    def initialize(name:, omit_output_fields: [], aspect_ratios: [], resolutions: [], **)
      super
      @aspect_ratios = aspect_ratios
      @resolutions = resolutions
    end
  end

  # @api private
  class DecisionModel < Model; end

  # @api private
  class EmbeddingModel < Model
    PLACEHOLDERS = %w[{instruction} {text}].freeze

    # How the model expects a query to carry the task it is embedded for, with `{instruction}` and
    # `{text}` where those go, or nil for a model that takes no instruction.
    attr_reader :instruction_format

    def initialize(name:, omit_output_fields: [], instruction_format: nil, **)
      super
      @instruction_format = instruction_format.presence
      return if @instruction_format.nil? || PLACEHOLDERS.all? { |marker| @instruction_format.include?(marker) }

      raise ArgumentError, "instruction_format for '#{name}' must contain #{PLACEHOLDERS.join(' and ')}"
    end

    # The text as the model receives it with the instruction, in one pass so an instruction that
    # happens to contain `{text}` is sent as written.
    def apply_instruction(instruction, text)
      values = { "instruction" => instruction, "text" => text }
      instruction_format.gsub(/\{(instruction|text)\}/) { values[Regexp.last_match(1)] }
    end
  end

  # @api private
  class RerankModel < Model; end

  # @api private
  class TextModel < Model; end

  # @api private
  class TextToSpeechModel < Model
    attr_reader :default_voice,
                :default_response_format,
                :voices,
                :response_formats

    def initialize(
      name:,
      default_voice:,
      default_response_format:,
      voices: [],
      response_formats: [],
      **
    )
      super
      @default_voice = default_voice
      @default_response_format = default_response_format
      @voices = voices
      @response_formats = response_formats
    end
  end
end
