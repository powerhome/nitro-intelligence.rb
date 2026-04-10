module NitroIntelligence
  class Model
    attr_reader :name, :omit_output_fields

    def initialize(name:, omit_output_fields: [], **)
      @name = name
      @omit_output_fields = omit_output_fields.map { |field| field.split(".").map(&:to_sym) }
    end
  end

  class TextModel < Model; end

  class ImageModel < Model
    attr_reader :aspect_ratios, :resolutions

    def initialize(name:, omit_output_fields: [], aspect_ratios: [], resolutions: [], **)
      super
      @aspect_ratios = aspect_ratios
      @resolutions = resolutions
    end
  end
end
