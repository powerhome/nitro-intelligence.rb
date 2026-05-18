require "openai"

module NitroIntelligence
  module Client
    module Handlers
      class TextToSpeechHandler
        ALLOWED_EXTRA_PARAMETERS = OpenAI::Models::Audio::SpeechCreateParams.fields.keys.uniq.freeze

        def initialize(client:)
          @client = client
        end

        def create(message: "", parameters: {})
          validate_and_resolve!(parameters)
          perform_request(message:, parameters:)
        end

        def perform_request(message: "", parameters: {})
          @client.audio.speech.create(
            input: message,
            **parameters.slice(*ALLOWED_EXTRA_PARAMETERS)
          )
        end

        def validate_and_resolve!(parameters)
          model_name = parameters[:model] || NitroIntelligence.model_catalog.default_text_to_speech_model&.name
          model = NitroIntelligence.model_catalog.lookup_by_name(model_name)

          # Check model supported
          raise ArgumentError, "Unsupported model: '#{model_name}'" unless model

          default_parameters = {
            metadata: {},
            model: model.name,
            voice: model.default_voice,
            response_format: model.default_response_format,
          }

          parameters.replace(default_parameters.merge(parameters))

          # Check voice supported
          unless model.voices.include?(parameters[:voice])
            raise ArgumentError,
                  "Unsupported voice: '#{parameters[:voice]}'. " \
                  "Supported voices for #{model.name} are: #{model.voices}"
          end

          # Check format supported
          return if model.response_formats.include?(parameters[:response_format])

          raise ArgumentError,
                "Unsupported response_format: '#{parameters[:response_format]}'. " \
                "Supported response_formats for #{model.name} are: #{model.response_formats}"
        end
      end
    end
  end
end
