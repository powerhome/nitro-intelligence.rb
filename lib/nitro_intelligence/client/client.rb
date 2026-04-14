require "nitro_intelligence/client/factory"

module NitroIntelligence
  module Client
    def self.new(observability_project_slug: nil)
      Factory.new(observability_project_slug:).build
    end

    def self.validate_model(model)
      raise ArgumentError, "Unsupported model: '#{model}'" unless NitroIntelligence.model_catalog.exists?(model)
    end
  end
end
