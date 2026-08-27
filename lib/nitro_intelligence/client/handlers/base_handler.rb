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
        TAGS_HEADER = "x-litellm-tags".freeze

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
        # when the request fails and never produces a response body; tags naming the
        # feature behind the request, so gateway spend and usage can be aggregated by
        # it; and the caller's metadata, so gateway spend can be attributed to the
        # work that caused it.
        #
        # The three are independent. Metadata is worth sending whether or not
        # anything is observing, whereas the trace ID and tags come from the observed
        # handlers. Neither is read from whatever tracing context happens to be
        # active: a host application with its own instrumentation has traces of its
        # own, and their IDs mean nothing to the observability platform.
        #
        # add_request_headers drops nil values, so each header appears only when it
        # has something to say.
        def add_correlation_headers(parameters, trace_id:)
          add_request_headers(
            parameters,
            TRACE_ID_HEADER => trace_id.presence,
            TAGS_HEADER => spend_tags(parameters[:gateway_tags]),
            SPEND_LOGS_METADATA_HEADER => spend_logs_metadata(parameters[:metadata])
          )
        end

        # Which requests are worth tagging is the observed layer's call - it is what
        # knows the observability project and the prompt behind a request - so this
        # only decides how the tags travel.
        #
        # Tags serve whoever operates the gateway, not the feature teams calling this
        # library: they read gateway spend, and feature teams read the observability
        # platform. Nothing here is caller-facing, which is why no parameter exposes
        # it and the README does not document it.
        #
        # Unlike spend logs metadata, which the gateway stores but offers no way to
        # query, tags are dimensions it aggregates spend and usage by
        # (`/spend/tags`, `/tag/daily/activity`). They aggregate rather than search:
        # the spend log list takes no tag filter, so picking one feature's requests
        # out means pulling a date range and filtering on each row's tags.
        # See https://docs.litellm.ai/docs/proxy/cost_tracking#custom-tags
        #
        # Note the gateway also reads this header for tag-based routing. That is off
        # unless `enable_tag_filtering` is set, but were it ever enabled, a request
        # whose tags match no deployment fails outright unless `allow_fail_open` is
        # set or deployments carry `tags: ["default"]`.
        # See https://docs.litellm.ai/docs/proxy/tag_routing
        def spend_tags(tags)
          return nil if tags.blank?

          tags.filter_map { |tag| sanitize_tag(tag).presence }.join(",").presence
        end

        # The gateway splits this header on commas, so a tag containing one would
        # silently become two. Collapsing commas and whitespace runs (which also
        # removes the newlines an HTTP client would reject outright) keeps a tag
        # findable rather than dropping it.
        def sanitize_tag(tag)
          tag.to_s.tr(",", " ").squish
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
