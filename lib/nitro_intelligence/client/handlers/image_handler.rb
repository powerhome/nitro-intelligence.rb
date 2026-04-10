require "openai"
require "nitro_intelligence/media/image_generation"

module NitroIntelligence
  module Client
    module Handlers
      class ImageHandler
        ALLOWED_EXTRA_PARAMETERS = OpenAI::Models::Chat::CompletionCreateParams.fields.keys.uniq.freeze

        def initialize(client:)
          @client = client
        end

        def create(message: "", target_image: nil, reference_images: [], parameters: {})
          image_generation = build_image_generation(message:, target_image:, reference_images:, parameters:)

          validate_and_resolve!(parameters, image_generation)

          chat_completion = perform_request(parameters:)

          image_generation.parse_file(chat_completion)
          image_generation
        end

        def perform_request(parameters: {})
          @client.chat.completions.create(**parameters.slice(*ALLOWED_EXTRA_PARAMETERS))
        end

        def validate_and_resolve!(parameters, image_generation)
          default_parameters = {
            image_generation:,
            metadata: {},
            messages: image_generation.messages,
            model: image_generation.config.model,
            extra_headers: { "Prefer" => "wait" },
            request_options: {
              extra_body: {
                image_config: {
                  aspect_ratio: image_generation.config.aspect_ratio,
                  image_size: image_generation.config.resolution,
                },
              },
            },
          }
          parameters.replace(default_parameters.merge(parameters))
          Client.validate_model(parameters[:model])
        end

      private

        def build_image_generation(message:, target_image:, reference_images:, parameters:)
          NitroIntelligence::ImageGeneration.new(message:, target_image:, reference_images:) do |config|
            config.aspect_ratio = parameters[:aspect_ratio] if parameters.key?(:aspect_ratio)
            config.model = parameters[:model] if parameters.key?(:model)
            config.resolution = parameters[:resolution] if parameters.key?(:resolution)
          end
        end
      end
    end
  end
end
