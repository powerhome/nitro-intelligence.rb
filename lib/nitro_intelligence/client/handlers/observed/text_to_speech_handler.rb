require "nitro_intelligence/media/audio"
require "nitro_intelligence/observability/prompt_resolver"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        # @api private
        class TextToSpeechHandler
          # Raised by {Client::Base#text_to_speech} on an observed client when the prompt it names
          # is not a text prompt.
          #
          # @api public
          class ObservedTextToSpeechPromptError < StandardError; end

          def initialize(base_handler:, observer:)
            @base_handler = base_handler
            @observer = observer
          end

          def create(message: "", parameters: {})
            prompt = handle_prompt(parameters:)

            @base_handler.validate_and_resolve!(parameters)

            trace_name = parameters[:trace_name] || prompt&.name || @observer.project_client.project.slug

            @observer.observe(
              "text-to-speech",
              type: :generation,
              parameters:,
              trace_name:,
              prompt:,
              input: message
            ) do |generation|
              workflow(generation:, message:, parameters:)
            end
          end

        private

          def handle_prompt(parameters:)
            prompt = NitroIntelligence::Observability::PromptResolver.for(
              store: @observer.project_client.project.prompt_store,
              parameters:
            )
            return nil if prompt.blank?

            # Prompts for tts should only be text
            if prompt.type != "text"
              raise ObservedTextToSpeechPromptError,
                    "Prompt type for text-to-speech must be text: #{prompt.name}"
            end
            interpolated_prompt = prompt.compile(**(parameters[:prompt_variables] || {}))

            parameters.merge!(prompt.config) unless parameters[:prompt_config_disabled]
            parameters[:instructions] = interpolated_prompt

            prompt
          end

          def handle_text_to_speech_upload(tts_file, trace_id, observation_id:)
            upload_handler = NitroIntelligence::Observability::UploadHandler.new(
              auth_token: @observer.project_client.project.auth_token
            )
            audio = Audio.new(tts_file)
            audio.direction = "output"

            upload_handler.upload(
              trace_id,
              observation_id:,
              upload_queue: Queue.new([audio])
            )

            uploaded_media = upload_handler.uploaded_media.first
            "@@@langfuseMedia:type=#{uploaded_media.mime_type}|id=#{uploaded_media.reference_id}|source=bytes@@@"
          end

          def workflow(generation:, message:, parameters:)
            tts = @base_handler.perform_request(message:, parameters:, correlation_trace_id: generation.trace_id)
            output = ""

            Tempfile.create(["tts", ".#{parameters[:response_format]}"]) do |tempfile|
              tempfile.binmode
              tempfile.write(tts.string)
              tempfile.rewind

              output = handle_text_to_speech_upload(tempfile, generation.trace_id, observation_id: generation.id)
            end

            # Usage details and the resolved model are read off a response body, and
            # this endpoint's body is audio, so neither is available here. The
            # requested model and the input are already on the observation from
            # before the request ran.
            trace_attributes = {
              output:,
              cost_details: @base_handler.cost_details(tts),
            }

            [tts, trace_attributes]
          end
        end
      end
    end
  end
end
