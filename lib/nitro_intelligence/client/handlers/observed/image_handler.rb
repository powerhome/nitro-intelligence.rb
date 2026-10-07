require "nitro_intelligence/media/image_generation"
require "nitro_intelligence/observability/prompt_resolver"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        class ImageHandler
          class ObservedImagePromptError < StandardError; end

          def initialize(base_handler:, observer:)
            @base_handler = base_handler
            @observer = observer
          end

          def create(message: "", target_image: nil, reference_images: [], parameters: {})
            prompt = resolve_prompt(parameters:)
            image_generation = build_image_generation(message:, target_image:, reference_images:, parameters:)

            @base_handler.validate_and_resolve!(parameters, image_generation)

            handle_prompt(parameters:, prompt:, image_generation:) if prompt
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
              config.size = parameters[:size] if parameters.key?(:size)
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

          def resolve_prompt(parameters:)
            prompt = NitroIntelligence::Observability::PromptResolver.for(
              store: @observer.project_client.project.prompt_store,
              parameters:
            )
            return nil if prompt.blank?

            parameters.merge!(prompt.config) unless parameters[:prompt_config_disabled]

            prompt
          end

          def handle_prompt(parameters:, prompt:, image_generation:)
            variables = parameters[:prompt_variables] || {}
            unless image_generation.edit?
              parameters[:messages] = prompt.interpolate(messages: parameters[:messages], variables:)
              return
            end

            unless prompt.type == "text"
              raise ObservedImagePromptError, "Image editing requires a Cerebro text prompt: #{prompt.name}"
            end

            parameters[:prompt] = [prompt.compile(**variables), parameters[:prompt]].reject(&:blank?).join("\n\n")
          end

          def workflow(generation:, image_generation:, parameters:)
            response = @base_handler.perform_request(parameters:, correlation_trace_id: generation.trace_id)

            image_generation.trace_id = generation.trace_id
            image_generation.parse_file(response)

            input, output = trace_payloads(response, image_generation, parameters)
            handle_image_generation_uploads(input, output, image_generation)

            trace_attributes = {
              model: response.respond_to?(:model) ? response.model : nil,
              model_parameters: image_generation.edit? ? edit_model_parameters(parameters) : nil,
              input:,
              output:,
              usage_details: usage_details(response),
              cost_details: @base_handler.cost_details(response),
            }

            [response, trace_attributes]
          end

          def trace_payloads(response, image_generation, parameters)
            return [parameters[:messages], response.choices.first.message.to_h] unless image_generation.edit?

            input = [{ role: "user", content: [
              { type: "text", text: parameters[:prompt] },
              *image_generation.input_images.map { |image| image_part(image) },
            ] }]
            output = { images: [image_part(image_generation.generated_image)] }
            [input, output]
          end

          def image_part(image)
            { type: "image_url", image_url: { url: "data:#{image.mime_type};base64,#{image.base64}" } }
          end

          def edit_model_parameters(parameters)
            fields = Handlers::ImageHandler::ALLOWED_EDIT_PARAMETERS - %i[model prompt image mask request_options]
            parameters.slice(*fields)
          end

          def usage_details(response)
            return unless response.usage

            fields = if response.respond_to?(:data)
                       %i[input_tokens output_tokens total_tokens]
                     else
                       %i[prompt_tokens completion_tokens total_tokens]
                     end
            fields.to_h { |field| [field, response.usage.public_send(field)] }.compact.presence
          end
        end
      end
    end
  end
end
