module NitroIntelligence
  class Model
    attr_reader :name, :omit_output_fields

    def initialize(name:, omit_output_fields: [], **)
      @name = name
      @omit_output_fields = omit_output_fields.map { |field| field.split(".").map(&:to_sym) }
    end
  end

  class ImageModel < Model
    attr_reader :aspect_ratios, :resolutions

    def initialize(name:, omit_output_fields: [], aspect_ratios: [], resolutions: [], **)
      super
      @aspect_ratios = aspect_ratios
      @resolutions = resolutions
    end
  end

  class TextModel < Model; end

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
