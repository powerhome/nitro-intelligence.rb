require "openai"
require "nitro_intelligence/client/handlers/base_handler"

module NitroIntelligence
  module Client
    module Handlers
      # The responses endpoint separates the instruction a model is given from the input it
      # answers, rather than folding both into one message list, and returns its output as
      # typed items: reasoning and message arrive alongside each other rather than the first
      # being a field of the second.
      class ResponsesHandler < BaseHandler
        ALLOWED_EXTRA_PARAMETERS = OpenAI::Models::Responses::ResponseCreateParams.fields.keys.uniq.freeze

        def create(message: "", parameters: {})
          validate_and_resolve!(parameters, message)
          perform_request(parameters:)
        end

        def perform_request(parameters: {}, correlation_trace_id: nil)
          add_request_headers(parameters, REQUESTED_MODEL_HEADER => parameters[:model])
          add_correlation_headers(parameters, trace_id: correlation_trace_id)
          @client.responses.create(**parameters.slice(*ALLOWED_EXTRA_PARAMETERS))
        end

        # `input` is deliberately left unset when the caller supplies nothing. The gateway
        # answers a missing `input` with a 500 and an empty one by manufacturing a turn the
        # caller never wrote, so neither is a safe default to send; the observed handler
        # refuses the request instead.
        def validate_and_resolve!(parameters, message)
          parameters[:input] = message if parameters[:input].blank? && message.present?

          default_parameters = {
            metadata: {},
            model: NitroIntelligence.model_catalog.default_text_model&.name,
          }

          parameters.replace(default_parameters.merge(parameters))
          Client.validate_model(parameters[:model])
        end
      end
    end
  end
end
