require "nitro_intelligence/models/model"

module NitroIntelligence
  class ModelFactory
    def self.build(model_metadata)
      model_metadata = model_metadata.symbolize_keys

      if image_model?(model_metadata)
        ImageModel.new(**model_metadata)
      else
        TextModel.new(**model_metadata)
      end
    end

    def self.image_model?(model_metadata)
      model_metadata.key?(:aspect_ratios) || model_metadata.key?(:resolutions)
    end
  end
end
