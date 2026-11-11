require "json"

module NitroIntelligence
  module Client
    # @api private
    module Handlers
      # @api private
      class BaseHandler
        MODALITY_HEADER = "nip-modality".freeze
        REQUESTED_MODEL_HEADER = "nip-requested-model".freeze

        # Correlation headers understood by the inference gateway (LiteLLM).
        # See https://docs.litellm.ai/docs/proxy/request_headers
        TRACE_ID_HEADER = "x-litellm-trace-id".freeze
        SPEND_LOGS_METADATA_HEADER = "x-litellm-spend-logs-metadata".freeze

        # Asks the gateway to replace the messages and the response with
        # "redacted-by-litellm" in its own logs. The gateway reads any value as on.
        MESSAGE_REDACTION_HEADER = "x-litellm-enable-message-redaction".freeze

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

        # A chat completion's message as Cerebro should record it, with its reasoning moved to
        # where Cerebro's formatted view shows it.
        #
        # The gateway returns reasoning as the message's `reasoning_content`, and LiteLLM repeats
        # it as `provider_specific_fields.reasoning`. Cerebro's formatted view reads neither: it
        # shows a message's reasoning only from its `thinking` list, so the text is otherwise
        # visible in the JSON view alone, and recorded twice. Here it is recorded once, as
        # `thinking`. Only reasoning that is text is moved: anything else a provider sends there,
        # and every other provider field, is kept as the gateway returned it.
        #
        # A copy, because openai-ruby's `to_h` is the message's own hash: changing it, or letting
        # the observer truncate it, would change the response the caller gets back.
        def recorded_message(message)
          recorded = message.to_h.deep_dup
          reasoning = reasoning_text(recorded[:reasoning_content])
          recorded.delete(:reasoning_content) if reasoning
          reasoning = take_provider_reasoning(recorded, reasoning) || reasoning

          recorded[:thinking] = [{ type: "thinking", content: reasoning }] if reasoning
          recorded
        end

        # The breakdowns of a chat completion's usage recorded in Cerebro, each under the name
        # Cerebro is sent and the names the gateway may report it under, first match winning.
        # Cerebro takes every breakdown it is sent out of the input or output count and records
        # it alongside, so only breakdowns that are part of that count and do not overlap one
        # another are sent. The gateway reports others that are not: it mirrors a cache write
        # as both `cache_write_tokens` and `cache_creation_tokens`, splits tokens by modality
        # (`text_tokens`, `image_tokens` and the like) across the cached and reasoning ones,
        # and adds counts such as `initial_prompt_tokens` that are not part of the input at all.
        PROMPT_TOKEN_DETAILS = {
          cached_tokens: %i[cached_tokens],
          cache_write_tokens: %i[cache_write_tokens cache_creation_tokens],
        }.freeze
        COMPLETION_TOKEN_DETAILS = {
          reasoning_tokens: %i[reasoning_tokens],
        }.freeze

        # A chat completion's token usage, in the shape the gateway reports it, breakdowns
        # included. Cerebro reads this shape itself: it records each breakdown under a key of
        # its own (reasoning as `output_reasoning_tokens`, cached input as
        # `input_cached_tokens`) and takes it out of the output or input count it belongs to,
        # so the total stays the one the gateway reported. Flattening a breakdown into a key of
        # our own would instead be counted on top of the output it is part of.
        def chat_usage_details(usage)
          {
            prompt_tokens: usage.prompt_tokens,
            completion_tokens: usage.completion_tokens,
            total_tokens: usage.total_tokens,
            prompt_tokens_details: token_counts(usage.prompt_tokens_details, PROMPT_TOKEN_DETAILS),
            completion_tokens_details: token_counts(usage.completion_tokens_details, COMPLETION_TOKEN_DETAILS),
          }.compact
        end

      private

        def reasoning_text(value)
          value if value.is_a?(String) && value.present?
        end

        # Removes LiteLLM's copy of the reasoning from the provider fields, and returns it, when it
        # is text that repeats the message's own or the message has none. Reasoning that says
        # something else, or is not text, is left where it is.
        def take_provider_reasoning(recorded, reasoning)
          provider_fields = recorded[:provider_specific_fields]
          return nil unless provider_fields.is_a?(Hash)

          provider_reasoning = reasoning_text(provider_fields[:reasoning])
          return nil unless provider_reasoning && (reasoning.nil? || provider_reasoning == reasoning)

          remaining = provider_fields.except(:reasoning)
          if remaining.empty?
            recorded.delete(:provider_specific_fields)
          else
            recorded[:provider_specific_fields] = remaining
          end
          provider_fields[:reasoning]
        end

        # The breakdowns `names` lists that `details` reports a count for. Cerebro rejects the
        # whole usage if any breakdown value is not a count, so a value that is not one is left
        # out rather than costing the generation its token counts.
        def token_counts(details, names)
          reported = details.to_h
          names.to_h do |name, aliases|
            [name, aliases.map { |key| reported[key] }.find { |value| value.is_a?(Integer) && value >= 0 }]
          end.compact.presence
        end

        # `last_response` carries the HTTP metadata of the response a model was built
        # from. The client leaves it unset on nested and locally constructed models,
        # so both the method and its value are optional.
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

        # Copies the request options rather than changing them, because a caller may pass one
        # hash to several requests, and the headers added here belong to this request alone.
        def add_request_headers(parameters, headers)
          request_options = parameters[:request_options].to_h
          parameters[:request_options] =
            request_options.merge(extra_headers: request_options[:extra_headers].to_h.merge(headers.compact))
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

        # Every request to the gateway names the model asked for, and the modality where the
        # route alone does not, carries the correlation headers and, for a project that masks
        # content, asks the gateway to redact it from its logs.
        def add_gateway_headers(parameters, correlation_trace_id:, mask_content:, modality: nil)
          add_request_headers(parameters, MODALITY_HEADER => modality, REQUESTED_MODEL_HEADER => parameters[:model])
          add_correlation_headers(parameters, trace_id: correlation_trace_id)
          add_message_redaction_header(parameters, mask_content:)
        end

        # A project that masks content in Cerebro keeps it out of the gateway's logs
        # too, so one setting decides where a request's content is recorded.
        def add_message_redaction_header(parameters, mask_content:)
          add_request_headers(parameters, MESSAGE_REDACTION_HEADER => ("true" if mask_content))
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
