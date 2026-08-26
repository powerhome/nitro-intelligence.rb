require "openai"
require "nitro_intelligence/client/handlers/base_handler"

module NitroIntelligence
  module Client
    module Handlers
      class ChatHandler < BaseHandler
        ALLOWED_EXTRA_PARAMETERS = OpenAI::Models::Chat::CompletionCreateParams.fields.keys.uniq.freeze

        def create(message: "", parameters: {})
          validate_and_resolve!(parameters, message)
          perform_request(parameters:)
        end

        def perform_request(parameters: {}, correlation_trace_id: nil)
          add_request_headers(parameters, REQUESTED_MODEL_HEADER => parameters[:model])
          add_correlation_headers(parameters, trace_id: correlation_trace_id)
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
          }

          parameters.replace(default_parameters.merge(parameters))
          Client.validate_model(parameters[:model])
        end
      end
    end
  end
end
