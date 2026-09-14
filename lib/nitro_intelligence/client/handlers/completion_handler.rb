require "openai"
require "nitro_intelligence/client/handlers/base_handler"

module NitroIntelligence
  module Client
    module Handlers
      # The completion endpoint takes a single prompt string and returns the text that
      # continues it, with none of the role structure a chat completion carries. It
      # reaches the model without a chat template, so what is sent is what the model
      # sees.
      class CompletionHandler < BaseHandler
        ALLOWED_EXTRA_PARAMETERS = OpenAI::Models::CompletionCreateParams.fields.keys.uniq.freeze

        def create(message: "", parameters: {})
          validate_and_resolve!(parameters, message)
          perform_request(parameters:)
        end

        def perform_request(parameters: {}, correlation_trace_id: nil)
          add_request_headers(parameters, REQUESTED_MODEL_HEADER => parameters[:model])
          add_correlation_headers(parameters, trace_id: correlation_trace_id)
          @client.completions.create(**parameters.slice(*ALLOWED_EXTRA_PARAMETERS))
        end

        def validate_and_resolve!(parameters, message)
          parameters[:prompt] = message if parameters[:prompt].blank? && message.present?

          default_parameters = {
            metadata: {},
            prompt: "",
            model: NitroIntelligence.model_catalog.default_text_model&.name,
          }

          parameters.replace(default_parameters.merge(parameters))
          Client.validate_model(parameters[:model])
        end
      end
    end
  end
end
