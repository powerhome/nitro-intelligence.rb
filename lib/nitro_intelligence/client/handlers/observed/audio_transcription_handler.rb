require "base64"
require "nitro_intelligence/media/audio"

module NitroIntelligence
  module Client
    module Handlers
      module Observed
        class AudioTranscriptionHandler
          class ObservedAudioTranscriptionPromptError < StandardError; end

          def initialize(base_handler:, observer:)
            @base_handler = base_handler
            @observer = observer
          end

          def create(audio_file:, message: +"", parameters: {})
            @base_handler.validate_and_resolve!(parameters)

            # Modifies message in place
            prompt = handle_prompt(message:, parameters:)
            trace_name = parameters[:trace_name] || prompt&.name || @observer.project_client.project.slug

            @observer.observe(
              "audio-transcription",
              type: :generation,
              parameters:,
              trace_name:,
              prompt:
            ) do |generation|
              workflow(generation:, message:, audio_file:, parameters:)
            end
          end

        private

          def handle_prompt(message:, parameters:)
            return nil if parameters[:prompt_name].blank?

            prompt = @observer.project_client.project.prompt_store.get_prompt(
              prompt_name: parameters[:prompt_name],
              prompt_label: parameters[:prompt_label],
              prompt_version: parameters[:prompt_version]
            )
            prompt_variables = parameters[:prompt_variables] || {}

            if prompt.present?
              # Prompts for audio transcriptions should only be text
              if prompt.type != "text"
                raise ObservedAudioTranscriptionPromptError,
                      "Prompt type for audio transcription must be text: #{prompt.name}"
              end
              interpolated_prompt = prompt.compile(**prompt_variables)

              message.prepend("#{interpolated_prompt} ").strip!
              parameters.merge!(prompt.config) unless parameters[:prompt_config_disabled]
            end

            prompt
          end

          def workflow(generation:, message:, audio_file:, parameters:)
            audio_transcription = @base_handler.perform_request(audio_file:, message:, parameters:)

            audio_file.rewind
            upload_handler = NitroIntelligence::Observability::UploadHandler.new(
              auth_token: @observer.project_client.project.auth_token
            )
            upload_handler.upload(
              generation.trace_id,
              upload_queue: Queue.new([NitroIntelligence::Audio.new(audio_file)])
            )

            trace_attributes = {
              model: parameters[:model], # Model isn't in response object OpenAI::Models::Audio::Transcription
              input: message,
              output: audio_transcription.text,
              usage_details: {
                input_tokens: audio_transcription.usage.input_tokens,
                output_tokens: audio_transcription.usage.output_tokens,
                total_tokens: audio_transcription.usage.total_tokens,
              },
            }

            [audio_transcription, trace_attributes]
          end
        end
      end
    end
  end
end
