require "nitro_intelligence/models/model_factory"

module NitroIntelligence
  class ModelCatalog
    attr_reader :models,
                :default_audio_transcription_model,
                :default_decision_model,
                :default_image_model,
                :default_text_model,
                :default_text_to_speech_model

    def initialize(model_config)
      model_config = model_config.symbolize_keys
      @models = (model_config[:models] || []).map { |model_metadata| ModelFactory.build(model_metadata) }
      @default_audio_transcription_model = lookup_by_name(model_config[:default_audio_transcription_model])
      @default_decision_model = lookup_by_name(model_config[:default_decision_model])
      @default_image_model = lookup_by_name(model_config[:default_image_model])
      @default_text_model = lookup_by_name(model_config[:default_text_model])
      @default_text_to_speech_model = lookup_by_name(model_config[:default_text_to_speech_model])
    end

    def lookup_by_name(name)
      @models.find { |model| model.name == name }
    end

    # The named model, checked to be of the type a request needs. A model of another type
    # would fail at the gateway, or deep in a handler's own validation, with an error that
    # does not say why.
    def fetch(name, type: Model)
      model = lookup_by_name(name)
      raise ArgumentError, "Unsupported model: '#{name}'" unless model

      return model if model.is_a?(type)

      article = type.kind.start_with?(/[aeiou]/) ? "an" : "a"
      raise ArgumentError, "Model '#{name}' is not #{article} #{type.kind} model"
    end

    def exists?(name)
      lookup_by_name(name).present?
    end
  end
end
