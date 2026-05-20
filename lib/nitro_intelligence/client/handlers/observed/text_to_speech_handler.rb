require "nitro_intelligence/media/audio"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        class TextToSpeechHandler
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
              prompt:
            ) do |generation|
              workflow(message:, parameters:, trace_id: generation.trace_id)
            end
          end

        private

          def handle_prompt(parameters:)
            return nil if parameters[:prompt_name].blank?

            prompt = @observer.project_client.project.prompt_store.get_prompt(
              prompt_name: parameters[:prompt_name],
              prompt_label: parameters[:prompt_label],
              prompt_version: parameters[:prompt_version]
            )
            prompt_variables = parameters[:prompt_variables] || {}

            if prompt.present?
              # Prompts for tts should only be text
              if prompt.type != "text"
                raise ObservedTextToSpeechPromptError,
                      "Prompt type for text-to-speech must be text: #{prompt.name}"
              end
              interpolated_prompt = prompt.compile(**prompt_variables)

              parameters.merge!(prompt.config) unless parameters[:prompt_config_disabled]
              parameters[:instructions] = interpolated_prompt
            end

            prompt
          end

          def handle_text_to_speech_upload(tts_file, trace_id)
            upload_handler = NitroIntelligence::Observability::UploadHandler.new(
              auth_token: @observer.project_client.project.auth_token
            )
            upload_handler.upload(
              trace_id,
              upload_queue: Queue.new([Audio.new(tts_file)])
            )

            uploaded_media = upload_handler.uploaded_media.first
            "@@@langfuseMedia:type=#{uploaded_media.mime_type}|id=#{uploaded_media.reference_id}|source=bytes@@@"
          end

          def workflow(message:, parameters:, trace_id:)
            tts = @base_handler.perform_request(message:, parameters:)
            output = ""

            Tempfile.create(["tts", ".#{parameters[:response_format]}"]) do |tempfile|
              tempfile.binmode
              tempfile.write(tts.string)
              tempfile.rewind

              output = handle_text_to_speech_upload(tempfile, trace_id)
            end

            # We only get StringIO object as a response
            # We dont have usage on tokens and the actual model that was used
            # We will log the requested model instead
            trace_attributes = {
              model: parameters[:model],
              input: message,
              output:,
            }

            [tts, trace_attributes]
          end
        end
      end
    end
  end
end
