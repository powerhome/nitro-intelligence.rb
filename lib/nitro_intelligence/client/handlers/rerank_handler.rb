require "openai"
require "nitro_intelligence/client/handlers/base_handler"
require "nitro_intelligence/ranking"

module NitroIntelligence
  module Client
    module Handlers
      # Ranks documents by their relevance to a query over the gateway's Cohere-compatible rerank
      # route, `POST /v1/rerank`. openai-ruby has no resource for it, so the request goes through
      # the client's generic `request`, which keeps its credentials, retries, timeouts and errors.
      #
      # @api private
      class RerankHandler < BaseHandler
        PATH = "v1/rerank".freeze
        # What is left of that route to add to an `inference_base_url` that already ends in `/v1`.
        PATH_AFTER_V1 = "rerank".freeze

        # Rerank request fields other than the model, query and documents, taken from `parameters`.
        BODY_PARAMETERS = %i[top_n].freeze

        # Declaring a model, rather than taking the decoded hash, is what gets the response its
        # `last_response`, and with it the gateway's cost headers. `Ranking` reads `results` and
        # `meta` raw through `BaseModel#[]`.
        class Response < OpenAI::BaseModel
          required :id, String, nil?: true
        end

        def create(query:, documents:, parameters: {})
          validate_and_resolve!(query, documents, parameters)
          perform_request(query:, documents:, parameters:)
        end

        def perform_request(query:, documents:, parameters: {}, correlation_trace_id: nil, mask_content: false)
          add_gateway_headers(parameters, correlation_trace_id:, mask_content:)
          response = @client.request(
            method: :post,
            path:,
            body: { model: parameters[:model], query:, documents:, **parameters.slice(*BODY_PARAMETERS).compact },
            model: Response,
            options: parameters[:request_options]
          )
          Ranking.new(response)
        end

        def validate_and_resolve!(query, documents, parameters)
          default_parameters = {
            metadata: {},
            model: NitroIntelligence.model_catalog.default_rerank_model&.name,
          }

          parameters.replace(default_parameters.merge(parameters))
          Client.validate_model(parameters[:model], type: RerankModel)
          raise ArgumentError, "query must be a non-empty string" unless query.is_a?(String) && query.present?
          return if documents.is_a?(Array) && documents.any? && documents.all?(String)

          raise ArgumentError, "documents must be a non-empty array of strings"
        end

      private

        # Both reach `/v1/rerank`: the whole route on a base URL without a version, or only the
        # rest of it on one that already ends in `/v1`.
        def path
          @client.base_url.path.chomp("/").end_with?("/v1") ? PATH_AFTER_V1 : PATH
        end
      end
    end
  end
end
