require "json"

module NitroIntelligence
  module Client
    module Handlers
      class BaseHandler
        MODALITY_HEADER = "nip-modality".freeze
        REQUESTED_MODEL_HEADER = "nip-requested-model".freeze

        # Correlation headers understood by the inference gateway (LiteLLM).
        # See https://docs.litellm.ai/docs/proxy/request_headers
        TRACE_ID_HEADER = "x-litellm-trace-id".freeze
        SPEND_LOGS_METADATA_HEADER = "x-litellm-spend-logs-metadata".freeze

        # Headers over ~8KB are rejected by most proxies. Metadata is caller
        # supplied, so cap it rather than turning a large hash into a failed request.
        MAX_SPEND_LOGS_METADATA_BYTES = 4096

        # Cost the inference gateway calculated for a response.
        # See https://docs.litellm.ai/docs/proxy/response_headers
        #
        # The gateway is the only component that knows which deployment actually
        # served a request, and the same model group can be served by internal
        # capacity or by any of several third-party providers at different rates.
        # Recomputing cost downstream from token counts therefore means maintaining
        # a second price table that silently drifts from the one doing the billing.
        RESPONSE_COST_HEADER = "x-litellm-response-cost".freeze
        RESPONSE_COST_INPUT_HEADER = "x-litellm-response-cost-input".freeze
        RESPONSE_COST_OUTPUT_HEADER = "x-litellm-response-cost-output".freeze

        def initialize(client:)
          @client = client
        end

        # Cost breakdown for an observation, or nil when the gateway did not price
        # the request.
        #
        # A deployment the gateway has no price for sends no cost header at all
        # rather than a zero one, so absence has to mean "unknown" here. Recording
        # nil leaves the generation without a cost; recording 0.0 would assert the
        # request was free and quietly understate spend for every model still
        # awaiting a price.
        #
        # Only the total is guaranteed. Where the cost comes from the upstream
        # provider rather than the gateway's own calculation - OpenRouter reports a
        # real per-request cost of its own, which the gateway passes through - there
        # is no component breakdown, so input and output appear only when sent.
        def cost_details(response)
          headers = response_headers(response)
          return nil if headers.nil?

          total = header_amount(headers, RESPONSE_COST_HEADER)
          return nil if total.nil?

          {
            total:,
            input: header_amount(headers, RESPONSE_COST_INPUT_HEADER),
            output: header_amount(headers, RESPONSE_COST_OUTPUT_HEADER),
          }.compact
        end

      private

        # `last_response` carries the HTTP metadata of the response a typed model was
        # built from. The client leaves it unset on nested and locally constructed
        # models, and on endpoints returning raw or binary payloads, so both the
        # method and its value are optional.
        def response_headers(response)
          return nil unless response.respond_to?(:last_response)

          response.last_response&.headers
        end

        # Header values arrive as strings. A malformed one is worth ignoring rather
        # than raising: a trace missing its cost is a far smaller problem than an
        # inference call failing because the gateway sent something unexpected.
        def header_amount(headers, name)
          value = headers[name]
          return nil if value.blank?

          Float(value)
        rescue ArgumentError, TypeError
          nil
        end

        def add_request_headers(parameters, headers)
          request_options = (parameters[:request_options] ||= {})
          (request_options[:extra_headers] ||= {}).merge!(headers.compact)
          parameters
        end

        # Hands the inference gateway what it needs to be matched up with the rest of
        # the picture: the trace ID the observability platform is recording this
        # request under, so a Langfuse trace can be found from a LiteLLM request even
        # when the request fails and never produces a response body, and the caller's
        # metadata, so gateway spend can be attributed to the work that caused it.
        #
        # The two are independent. Metadata is worth sending whether or not anything
        # is observing, whereas the trace ID is supplied by the observed handlers and
        # is never read from whatever tracing context happens to be active: a host
        # application with its own instrumentation has traces of its own, and their
        # IDs mean nothing to the observability platform.
        #
        # add_request_headers drops nil values, so each header appears only when it
        # has something to say.
        def add_correlation_headers(parameters, trace_id:)
          add_request_headers(
            parameters,
            TRACE_ID_HEADER => trace_id.presence,
            SPEND_LOGS_METADATA_HEADER => spend_logs_metadata(parameters[:metadata])
          )
        end

        def spend_logs_metadata(metadata)
          return nil if metadata.blank?

          json = metadata.to_json
          return json if json.bytesize <= MAX_SPEND_LOGS_METADATA_BYTES

          NitroIntelligence.logger.warn(
            "#{self.class} metadata is #{json.bytesize} bytes, over the " \
            "#{MAX_SPEND_LOGS_METADATA_BYTES} byte #{SPEND_LOGS_METADATA_HEADER} limit - omitting it"
          )
          nil
        end
      end
    end
  end
end
