require "openai"

module NitroIntelligence
  module Client
    module Handlers
      class ChatHandler
        ALLOWED_EXTRA_PARAMETERS = OpenAI::Models::Chat::CompletionCreateParams.fields.keys.uniq.freeze

        def initialize(client:)
          @client = client
        end

        def create(message: "", parameters: {})
          validate_and_resolve!(parameters, message)
          perform_request(parameters:)
        end

        def perform_request(parameters: {})
          @client.chat.completions.create(**parameters.slice(*ALLOWED_EXTRA_PARAMETERS))
        end

        def validate_and_resolve!(parameters, message)
          if parameters[:messages].blank? && message.present?
            parameters[:messages] ||= [{ role: "user",
                                         content: message }]
          end

          default_parameters = {
            metadata: {},
            messages: [],
            model: NitroIntelligence.model_catalog.default_text_model&.name,
            extra_headers: { "Prefer" => "wait" },
          }

          parameters.replace(default_parameters.merge(parameters))
          Client.validate_model(parameters[:model])
        end
      end
    end
  end
end
