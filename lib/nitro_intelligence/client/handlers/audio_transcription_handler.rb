require "openai"

module NitroIntelligence
  module Client
    module Handlers
      class AudioTranscriptionHandler
        ALLOWED_EXTRA_PARAMETERS = OpenAI::Models::Audio::TranscriptionCreateParams.fields.keys.uniq.freeze

        def initialize(client:)
          @client = client
        end

        def create(audio_file:, message: "", parameters: {})
          validate_and_resolve!(parameters)
          perform_request(audio_file:, message:, parameters:)
        end

        def perform_request(audio_file:, message: "", parameters: {})
          @client.audio.transcriptions.create(
            prompt: message,
            file: audio_file,
            **parameters.slice(*ALLOWED_EXTRA_PARAMETERS)
          )
        end

        def validate_and_resolve!(parameters)
          default_parameters = {
            metadata: {},
            model: NitroIntelligence.model_catalog.default_audio_transcription_model&.name,
          }

          parameters.replace(default_parameters.merge(parameters))
          Client.validate_model(parameters[:model])
        end
      end
    end
  end
end
