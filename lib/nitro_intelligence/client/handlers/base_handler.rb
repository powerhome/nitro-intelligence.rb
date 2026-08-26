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

        def initialize(client:)
          @client = client
        end

      private

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
