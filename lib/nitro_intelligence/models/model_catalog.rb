require "nitro_intelligence/models/model_factory"

module NitroIntelligence
  class ModelCatalog
    attr_reader :models, :default_audio_transcription_model, :default_image_model, :default_text_model

    def initialize(model_config)
      @models = (model_config[:models] || []).map { |model_metadata| ModelFactory.build(model_metadata) }
      @default_audio_transcription_model = lookup_by_name(model_config[:default_audio_transcription_model])
      @default_image_model = lookup_by_name(model_config[:default_image_model])
      @default_text_model = lookup_by_name(model_config[:default_text_model])
    end

    def lookup_by_name(name)
      @models.find { |model| model.name == name }
    end

    def exists?(name)
      lookup_by_name(name).present?
    end
  end
end
