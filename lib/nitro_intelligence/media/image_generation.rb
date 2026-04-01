require "base64"
require "digest"
require "mini_magick"
require "stringio"
require "time"

require "nitro_intelligence/media/image"

module NitroIntelligence
  class ImageGeneration
    class Config
      CUSTOM_PARAMS = %i[aspect_ratio image_generation resolution].freeze
      DEFAULT_ASPECT_RATIO = "1:1".freeze
      DEFAULT_RESOLUTION = "1K".freeze

      attr_accessor :aspect_ratio, :model, :resolution

      def initialize
        @aspect_ratio = DEFAULT_ASPECT_RATIO
        @model = NitroIntelligence.model_catalog.default_image_model.name
        @resolution = DEFAULT_RESOLUTION
      end
    end

    attr_reader :byte_string, :config, :file_type, :file_extension, :generated_image, :messages, :reference_images,
                :target_image
    attr_accessor :trace_id

    def initialize(
      message: "",
      target_image: nil,
      reference_images: []
    )
      @config = Config.new
      @generated_image = nil
      @model = NitroIntelligence.model_catalog.lookup_by_name(@config.model)
      @reference_images = reference_images.map { |img| Image.new(img) }
      @trace_id = nil

      # Overrides
      yield(@config) if block_given?
      validate_config!

      if target_image
        @target_image = Image.new(target_image)
        configure_aspect_ratio
      end

      build_messages(message, @target_image, @reference_images)
    end

    def files
      [target_image, reference_images, generated_image].flatten.compact
    end

    def parse_file(chat_completion)
      base64_string = chat_completion.choices.first&.message.to_h.fetch(:images, {})&.first&.dig(:image_url, :url)

      return unless base64_string

      @generated_image = Image.from_base64(base64_string)
      @generated_image.direction = "output"
      @generated_image
    end

  private

    def build_messages(message, target_image, reference_images)
      messages = [{ role: "user", content: [] }]

      messages.first[:content].append({ type: "text", text: message }) if message.present?

      if target_image
        messages.first[:content].append(image_message(mime_type: target_image.mime_type, base64: target_image.base64))
      end

      reference_images.each do |img|
        messages.first[:content].append(image_message(mime_type: img.mime_type, base64: img.base64))
      end

      @messages = messages
    end

    def calculate_aspect_ratios
      @model.aspect_ratios.index_by { |x| x.split(":").map(&:to_f).reduce(:/) }
    end

    def closest_aspect_ratio(width, height)
      actual_ratio = width.to_f / height
      calculated_aspect_ratios = calculate_aspect_ratios
      best_match = calculated_aspect_ratios.keys.min_by { |ratio_val| (ratio_val - actual_ratio).abs }
      calculated_aspect_ratios[best_match]
    end

    def configure_aspect_ratio
      @config.aspect_ratio = closest_aspect_ratio(@target_image.width, @target_image.height)
    end

    def image_message(url: nil, mime_type: nil, base64: nil)
      url = "data:#{mime_type};base64,#{base64}" if url.nil?

      {
        type: "image_url",
        image_url: {
          url:,
        },
      }
    end

    def validate_config!
      # Check model supported
      @model = NitroIntelligence.model_catalog.lookup_by_name(@config.model)
      raise ArgumentError, "Unsupported model: '#{@config.model}'" unless @model

      # Check aspect_ratio supported
      unless @model.aspect_ratios.include?(@config.aspect_ratio)
        raise ArgumentError,
              "Unsupported aspect ratio: '#{@config.aspect_ratio}'. " \
              "Supported ratios for #{@config.model} are: #{@model.aspect_ratios}"
      end

      # Check resolution supported
      return if @model.resolutions.include?(@config.resolution)

      raise ArgumentError,
            "Unsupported resolution: '#{@config.resolution}'. " \
            "Supported resolutions for #{@config.model} are: #{@model.resolutions}"
    end
  end
end
