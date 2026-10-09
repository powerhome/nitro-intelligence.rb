require "openai"
require "nitro_intelligence/client/handlers/base_handler"
require "nitro_intelligence/media/image_generation"

module NitroIntelligence
  module Client
    module Handlers
      class ImageHandler < BaseHandler
        ALLOWED_EXTRA_PARAMETERS = OpenAI::Models::Chat::CompletionCreateParams.fields.keys.uniq.freeze
        ALLOWED_EDIT_PARAMETERS = OpenAI::Models::ImageEditParams.fields.keys.uniq.freeze

        def create(message: "", target_image: nil, reference_images: [], parameters: {})
          image_generation = build_image_generation(message:, target_image:, reference_images:, parameters:)

          validate_and_resolve!(parameters, image_generation)

          chat_completion = perform_request(parameters:)

          image_generation.parse_file(chat_completion)
          image_generation
        end

        def perform_request(parameters: {}, correlation_trace_id: nil)
          add_request_headers(parameters, MODALITY_HEADER => "image", REQUESTED_MODEL_HEADER => parameters[:model])
          add_correlation_headers(parameters, trace_id: correlation_trace_id)
          if parameters[:image_generation].edit?
            validate_edit_parameters!(parameters)
            @client.images.edit(**parameters.slice(*ALLOWED_EDIT_PARAMETERS))
          else
            @client.chat.completions.create(**parameters.slice(*ALLOWED_EXTRA_PARAMETERS))
          end
        end

        def validate_and_resolve!(parameters, image_generation)
          default_parameters = {
            image_generation:,
            metadata: {},
            model: image_generation.config.model,
          }.merge(image_generation.edit? ? edit_parameters(image_generation) : generation_parameters(image_generation))
          parameters.replace(default_parameters.merge(parameters))
          Client.validate_model(parameters[:model])
        end

      private

        def build_image_generation(message:, target_image:, reference_images:, parameters:)
          NitroIntelligence::ImageGeneration.new(message:, target_image:, reference_images:) do |config|
            config.aspect_ratio = parameters[:aspect_ratio] if parameters.key?(:aspect_ratio)
            config.model = parameters[:model] if parameters.key?(:model)
            config.resolution = parameters[:resolution] if parameters.key?(:resolution)
            config.size = parameters[:size] if parameters.key?(:size)
          end
        end

        def edit_parameters(image_generation)
          {
            prompt: image_generation.message,
            image: image_generation.input_images.each_with_index.map do |image, index|
              OpenAI::FilePart.new(
                image.byte_string,
                filename: "image-#{index + 1}.#{image.file_extension}",
                content_type: image.mime_type
              )
            end,
            size: image_generation.requested_size,
          }
        end

        def generation_parameters(image_generation)
          {
            messages: image_generation.messages,
            request_options: {
              extra_body: {
                image_config: {
                  aspect_ratio: image_generation.config.aspect_ratio,
                  image_size: image_generation.config.resolution,
                },
              },
            },
          }
        end

        def validate_edit_parameters!(parameters)
          unless parameters[:prompt].is_a?(String) && parameters[:prompt].present?
            raise ArgumentError, "Image editing requires a message or a Cerebro text prompt."
          end

          unsupported = parameters.keys & (ALLOWED_EXTRA_PARAMETERS - ALLOWED_EDIT_PARAMETERS - [:metadata])
          return if unsupported.empty?

          raise ArgumentError, "Chat parameters are not supported for image edits: #{unsupported.join(', ')}"
        end
      end
    end
  end
end
