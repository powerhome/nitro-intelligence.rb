require "base64"
require "nitro_intelligence/media/audio"
require "nitro_intelligence/observability/prompt_resolver"

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
            trace_name = parameters[:trace_name] || prompt&.name || project.slug

            @observer.observe(
              "audio-transcription",
              type: :generation,
              parameters:,
              trace_name:,
              prompt:,
              input: message
            ) do |generation|
              workflow(generation:, message:, audio_file:, parameters:)
            end
          end

        private

          def project
            @observer.project_client.project
          end

          def handle_prompt(message:, parameters:)
            prompt = NitroIntelligence::Observability::PromptResolver.for(
              store: project.prompt_store,
              parameters:
            )
            return nil if prompt.blank?

            # Prompts for audio transcriptions should only be text
            if prompt.type != "text"
              raise ObservedAudioTranscriptionPromptError,
                    "Prompt type for audio transcription must be text: #{prompt.name}"
            end
            interpolated_prompt = prompt.compile(**(parameters[:prompt_variables] || {}))

            message.prepend("#{interpolated_prompt} ").strip!
            parameters.merge!(prompt.config) unless parameters[:prompt_config_disabled]

            prompt
          end

          # Uploads go to Cerebro's media API directly, past any masking, so a masked
          # project does not send the audio at all.
          def upload_input_audio(audio_file, trace_id)
            return if project.mask_content?

            audio_file.rewind
            upload_handler = NitroIntelligence::Observability::UploadHandler.new(
              auth_token: project.auth_token
            )
            upload_handler.upload(
              trace_id,
              upload_queue: Queue.new([NitroIntelligence::Audio.new(audio_file)])
            )
          end

          def workflow(generation:, message:, audio_file:, parameters:)
            audio_transcription = @base_handler.perform_request(
              audio_file:, message:, parameters:,
              correlation_trace_id: generation.trace_id, mask_content: project.mask_content?
            )

            upload_input_audio(audio_file, generation.trace_id)

            # The model and input are already recorded on the observation before the
            # request runs, and the response carries no model of its own
            # (OpenAI::Models::Audio::Transcription), so neither is set again here.
            trace_attributes = {
              output: audio_transcription.text,
              usage_details: usage_details(audio_transcription.usage),
              cost_details: @base_handler.cost_details(audio_transcription),
            }

            [audio_transcription, trace_attributes]
          end

          def usage_details(usage)
            case usage
            when OpenAI::Models::Audio::Transcription::Usage::Tokens
              {
                input_tokens: usage.input_tokens,
                output_tokens: usage.output_tokens,
                total_tokens: usage.total_tokens,
              }
            when OpenAI::Models::Audio::Transcription::Usage::Duration
              { input_audio_seconds: usage.seconds.ceil }
            end
          end
        end
      end
    end
  end
end
