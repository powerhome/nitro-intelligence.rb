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
        # `/v1/systemone` is the route the gateway's docs name and key route limits list. The
        # gateway also serves `/systemone`, which is what is left to add when `inference_base_url`
        # already ends in `/v1`.
        PATH = "v1/systemone".freeze
        VERSIONED_BASE_PATH = "systemone".freeze

        # System One request fields other than the model, state and questions, taken from
        # `parameters`. Everything else there is for the client, the gateway or tracing.
        BODY_PARAMETERS = %i[assets].freeze

        # Declaring a model, rather than taking the decoded hash, is what gets the response its
        # `last_response`, and with it the gateway's cost headers. Only `model` is declared:
        # `Decision` reads `answers` and `usage` raw through `BaseModel#[]`, which openai-ruby
        # documents as public API for keys outside a model's spec, from 0.86 through 0.99 at least.
        class Response < OpenAI::BaseModel
          required :model, String
        end

        def create(state:, questions:, parameters: {})
          validate_and_resolve!(parameters)
          perform_request(state:, questions:, parameters:)
        end

        def perform_request(state:, questions:, parameters: {}, correlation_trace_id: nil, mask_content: false)
          add_gateway_headers(parameters, correlation_trace_id:, mask_content:)
          response = @client.request(
            method: :post,
            path: @client.base_url.path.chomp("/").end_with?("/v1") ? VERSIONED_BASE_PATH : PATH,
            body: { model: parameters[:model], state:, questions:, **parameters.slice(*BODY_PARAMETERS).compact },
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
          Client.validate_model(parameters[:model], type: DecisionModel)
        end
      end
    end
  end
end
