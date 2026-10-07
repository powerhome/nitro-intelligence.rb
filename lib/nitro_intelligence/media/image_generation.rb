require "base64"
require "digest"
require "mini_magick"
require "stringio"
require "time"

require "nitro_intelligence/media/image"

module NitroIntelligence
  class ImageGeneration
    class ImageResponseError < StandardError; end

    class Config
      DEFAULT_ASPECT_RATIO = "1:1".freeze
      DEFAULT_RESOLUTION = "1K".freeze

      attr_accessor :model, :resolution, :size
      attr_writer :aspect_ratio

      def initialize
        @model = NitroIntelligence.model_catalog.default_image_model&.name
        @resolution = DEFAULT_RESOLUTION
      end

      def aspect_ratio
        @aspect_ratio || DEFAULT_ASPECT_RATIO
      end

      def aspect_ratio_set?
        !@aspect_ratio.nil?
      end
    end

    attr_reader :byte_string, :config, :file_type, :file_extension, :generated_image, :messages, :reference_images,
                :target_image, :message
    attr_accessor :trace_id

    def initialize(
      message: "",
      target_image: nil,
      reference_images: []
    )
      @config = Config.new
      @generated_image = nil
      @message = message
      @model = NitroIntelligence.model_catalog.lookup_by_name(@config.model)
      @reference_images = reference_images.map { |img| Image.new(img) }
      @trace_id = nil

      # Overrides
      yield(@config) if block_given?
      validate_config!

      if target_image
        @target_image = Image.new(target_image)
        configure_aspect_ratio unless @config.aspect_ratio_set? || @config.size
      end

      build_messages(message, @target_image, @reference_images)
    end

    def files
      [target_image, reference_images, generated_image].flatten.compact
    end

    def input_images
      [target_image, *reference_images].compact
    end

    def edit?
      input_images.any?
    end

    def requested_size
      return config.size if config.size

      side = resolution_side
      ratio = config.aspect_ratio.split(":").map(&:to_f).reduce(:/)
      width = [(side * Math.sqrt(ratio) / 16).round, 1].max * 16
      height = [(side / Math.sqrt(ratio) / 16).round, 1].max * 16
      "#{width}x#{height}"
    end

    def parse_file(response)
      @generated_image = response.respond_to?(:data) ? parse_edit_response(response) : parse_chat_response(response)
      @generated_image.direction = "output" if @generated_image
      @generated_image
    end

  private

    def parse_edit_response(response)
      image = response.data&.first
      raise ImageResponseError, "Image edit response contains no image." unless image

      return Image.from_base64(image.b64_json) if image.b64_json.present?

      url = image.url
      raise ImageResponseError, "Image edit response contains neither b64_json nor url." if url.blank?

      url.start_with?("data:") ? Image.from_base64(url) : Image.from_url(url)
    end

    def parse_chat_response(response)
      base64_string = response.choices.first&.message.to_h.fetch(:images, {})&.first&.dig(:image_url, :url)
      Image.from_base64(base64_string) if base64_string
    rescue ArgumentError
      NitroIntelligence.logger.info("Skipping image parse due to invalid base64; likely already parsed.")
      nil
    end

    def resolution_side
      { "512" => 512, "0.5K" => 512, "1K" => 1024, "2K" => 2048, "4K" => 4096 }.fetch(config.resolution) do
        raise ArgumentError, "Cannot translate resolution #{config.resolution.inspect} into size; pass size instead."
      end
    end

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
      return "#{width}:#{height}" if @model.aspect_ratios.empty?

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

      return validate_size! if @config.size

      validate_aspect_ratio!

      return if @model.resolutions.empty? || @model.resolutions.include?(@config.resolution)

      raise ArgumentError,
            "Unsupported resolution: '#{@config.resolution}'. " \
            "Supported resolutions for #{@config.model} are: #{@model.resolutions}"
    end

    def validate_size!
      return if @config.size.is_a?(String) && @config.size.match?(/\A(?:auto|[1-9]\d*x[1-9]\d*)\z/)

      raise ArgumentError, "Image size must be 'auto' or positive WIDTHxHEIGHT dimensions."
    end

    def validate_aspect_ratio!
      unless @config.aspect_ratio.is_a?(String) && @config.aspect_ratio.match?(/\A[1-9]\d*:[1-9]\d*\z/)
        raise ArgumentError, "Aspect ratio must contain two positive integers, such as '4:3'."
      end

      # Check aspect_ratio supported
      return if @model.aspect_ratios.empty? || @model.aspect_ratios.include?(@config.aspect_ratio)

      raise ArgumentError,
            "Unsupported aspect ratio: '#{@config.aspect_ratio}'. " \
            "Supported ratios for #{@config.model} are: #{@model.aspect_ratios}"
    end
  end
end
