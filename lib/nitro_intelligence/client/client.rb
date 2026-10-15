require "nitro_intelligence/client/factory"

module NitroIntelligence
  module Client
    def self.new(observability_project_slug: nil, inference_max_retries: nil, inference_timeout: nil)
      Factory.new(observability_project_slug:, inference_max_retries:, inference_timeout:).build
    end

    def self.validate_model(model)
      raise ArgumentError, "Unsupported model: '#{model}'" unless NitroIntelligence.model_catalog.exists?(model)
    end
  end
end
