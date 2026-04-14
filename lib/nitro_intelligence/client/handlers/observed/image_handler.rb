require "nitro_intelligence/media/image_generation"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        class ImageHandler
          def initialize(base_handler:, observer:)
            @base_handler = base_handler
            @observer = observer
          end

          def create(message: "", target_image: nil, reference_images: [], parameters: {})
            image_generation = build_image_generation(message:, target_image:, reference_images:, parameters:)

            @base_handler.validate_and_resolve!(parameters, image_generation)

            # Modifies parameters in place
            prompt = handle_prompt(parameters:)
            trace_name = parameters[:trace_name] || prompt&.name || @observer.project_client.project.slug

            @observer.observe(
              "image-generation",
              type: :generation,
              parameters:,
              trace_name:,
              prompt:
            ) do |generation|
              workflow(generation:, image_generation:, parameters:)
            end

            image_generation
          end

        private

          def build_image_generation(message:, target_image:, reference_images:, parameters:)
            NitroIntelligence::ImageGeneration.new(message:, target_image:, reference_images:) do |config|
              config.aspect_ratio = parameters[:aspect_ratio] if parameters.key?(:aspect_ratio)
              config.model = parameters[:model] if parameters.key?(:model)
              config.resolution = parameters[:resolution] if parameters.key?(:resolution)
            end
          end

          def handle_image_generation_uploads(input, output, image_generation)
            # If we are doing image generation we should upload the media to observability manually
            upload_handler = NitroIntelligence::Observability::UploadHandler.new(
              auth_token: @observer.project_client.project.auth_token
            )
            upload_handler.upload(
              image_generation.trace_id,
              upload_queue: Queue.new(image_generation.files)
            )

            # Replace base64 strings with media references
            upload_handler.replace_base64_with_media_references(input)
            upload_handler.replace_base64_with_media_references(output)
          end

          def handle_prompt(parameters:)
            return nil if parameters[:prompt_name].blank?

            prompt = @observer.project_client.project.prompt_store.get_prompt(
              prompt_name: parameters[:prompt_name],
              prompt_label: parameters[:prompt_label],
              prompt_version: parameters[:prompt_version]
            )
            prompt_variables = parameters[:prompt_variables] || {}

            if prompt.present?
              parameters[:messages] = prompt.interpolate(
                messages: parameters[:messages],
                variables: prompt_variables
              )

              parameters.merge!(prompt.config) unless parameters[:prompt_config_disabled]
            end

            prompt
          end

          def workflow(generation:, image_generation:, parameters:)
            chat_completion = @base_handler.perform_request(parameters:)

            image_generation.trace_id = generation.trace_id
            image_generation.parse_file(chat_completion)

            input = parameters[:messages]
            output = chat_completion.choices.first.message.to_h
            handle_image_generation_uploads(input, output, image_generation)

            trace_attributes = {
              model: chat_completion.model,
              input:,
              output:,
              usage_details: {
                prompt_tokens: chat_completion.usage.prompt_tokens,
                completion_tokens: chat_completion.usage.completion_tokens,
                total_tokens: chat_completion.usage.total_tokens,
              },
            }

            [chat_completion, trace_attributes]
          end
        end
      end
    end
  end
end
