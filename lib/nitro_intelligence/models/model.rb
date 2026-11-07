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
    # What the model expects before a query's text and before a document's, for a model trained
    # to embed the two differently. Empty for a model that embeds both the same way.
    attr_reader :query_prefix, :document_prefix

    def initialize(name:, omit_output_fields: [], query_prefix: "", document_prefix: "", **)
      super
      @query_prefix = query_prefix.to_s
      @document_prefix = document_prefix.to_s
    end

    # @param input_type [Symbol] `:query` or `:document`
    def prefix_for(input_type)
      input_type == :query ? query_prefix : document_prefix
    end
  end

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
