require "openai"
require "nitro_intelligence/client/handlers/base_handler"
require "nitro_intelligence/decision"

module NitroIntelligence
  module Client
    module Handlers
      # Asks a decision model questions about some content over the gateway's System One route,
      # `POST /v1/systemone`. openai-ruby has no resource for it, so the request goes through
      # the client's generic `request`, which keeps its credentials, retries, timeouts and errors.
      class DecisionHandler < BaseHandler
        # Relative to `inference_base_url`, which carries no `/v1`, like the paths openai-ruby
        # uses for chat and speech. The gateway serves the route at both `/systemone` and
        # `/v1/systemone`.
        PATH = "systemone".freeze

        # Declaring a model, rather than taking the decoded hash, is what gets the response its
        # `last_response`, and with it the gateway's cost headers.
        class Response < OpenAI::BaseModel
          required :model, String
        end

        def create(state:, questions:, parameters: {})
          validate_and_resolve!(parameters)
          perform_request(state:, questions:, parameters:)
        end

        def perform_request(state:, questions:, parameters: {}, correlation_trace_id: nil)
          add_request_headers(parameters, REQUESTED_MODEL_HEADER => parameters[:model])
          add_correlation_headers(parameters, trace_id: correlation_trace_id)
          response = @client.request(
            method: :post,
            path: PATH,
            body: { model: parameters[:model], state:, questions: },
            model: Response,
            options: parameters[:request_options]
          )
          Decision.new(response)
        end

        def validate_and_resolve!(parameters)
          default_parameters = {
            metadata: {},
            model: NitroIntelligence.model_catalog.default_decision_model&.name,
          }

          parameters.replace(default_parameters.merge(parameters))
          Client.validate_model(parameters[:model])
          return if NitroIntelligence.model_catalog.lookup_by_name(parameters[:model]).is_a?(DecisionModel)

          # A decision request has nothing in common with a chat one, so a model of another type
          # would fail at the gateway with an error that does not say why.
          raise ArgumentError, "Model '#{parameters[:model]}' is not a decision model"
        end
      end
    end
  end
end
