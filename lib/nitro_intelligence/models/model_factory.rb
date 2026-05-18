require "nitro_intelligence/models/model"

module NitroIntelligence
  class ModelFactory
    TYPES = {
      "text" => TextModel,
      "audio_transcription" => TextModel,
      "image" => ImageModel,
      "text_to_speech" => TextToSpeechModel,
    }.freeze

    def self.build(model_metadata)
      model_metadata = model_metadata.symbolize_keys
      type = model_metadata[:type]
      model_class = TYPES.fetch(type) { raise ArgumentError, "Unknown model type: #{type.inspect}" }
      model_class.new(**model_metadata)
    end
  end
end
