require "json"
require "opentelemetry"

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

        def initialize(client:)
          @client = client
        end

      private

        def add_request_headers(parameters, headers)
          request_options = (parameters[:request_options] ||= {})
          (request_options[:extra_headers] ||= {}).merge!(headers.compact)
          parameters
        end

        # Hands the inference gateway the trace ID the observability platform is
        # recording this request under, so a Langfuse trace can be matched to a
        # LiteLLM request even when the request fails and never produces a
        # response body. Also injects W3C trace context so the gateway nests its
        # own spans under ours when it has OpenTelemetry enabled.
        #
        # No-ops for the unobserved client, where there is no span to correlate to.
        def add_correlation_headers(parameters)
          span_context = OpenTelemetry::Trace.current_span.context
          return parameters unless span_context.valid?

          headers = { TRACE_ID_HEADER => span_context.hex_trace_id }
          OpenTelemetry.propagation.inject(headers)
          headers[SPEND_LOGS_METADATA_HEADER] = spend_logs_metadata(parameters[:metadata])

          add_request_headers(parameters, headers)
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
