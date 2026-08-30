module NitroIntelligence
  module Client
    module Observers
      class LangfuseObserver
        # The inference gateway returns its own request identifier on every
        # response, including error responses. Recording it on the observation is
        # the only way to line a failed generation up with the gateway's logs.
        # See https://docs.litellm.ai/docs/proxy/response_headers
        LITELLM_CALL_ID_HEADER = "x-litellm-call-id".freeze

        MAX_STATUS_MESSAGE_LENGTH = 2000

        attr_reader :project_client

        def initialize(project_client:)
          @project_client = project_client
        end

        def observe(operation_name, type:, parameters:, trace_name:, prompt: nil, input: nil) # rubocop:disable Metrics/AbcSize
          metadata = parameters[:metadata]
          seed = parameters[:trace_seed]
          trace_id = NitroIntelligence::Trace.create_id(seed:) if seed.present?

          if prompt
            metadata[:prompt_name] = prompt.name
            metadata[:prompt_version] = prompt.version
          end

          metadata = metadata.transform_values(&:to_s)

          Langfuse.propagate_attributes(**propagated_attributes(parameters, metadata)) do
            @project_client.observability_client.observe(
              operation_name,
              as_type: type,
              trace_id:,
              environment: NitroIntelligence.environment.to_s,
              model: parameters[:model],
              metadata:
            ) do |generation|
              generation.update_trace(name: trace_name, release: NitroIntelligence.configuration.current_revision)
              generation.update({ prompt: { name: prompt.name, version: prompt.version } }) if prompt
              record_input(generation, input)

              result, trace_attributes = observe_failures(generation) { yield(generation) }
              record_result(generation, trace_attributes)

              result
            end
          end
        end

      private

        # Applied once the response is in hand, so the observation reflects what came
        # back rather than what was asked for. Each attribute is set only when the
        # handler supplied it: an observation that records nothing is better than one
        # asserting a value the response never carried. Cost is the clearest case -
        # the gateway omits the header entirely for a deployment it has no price for,
        # and writing a zero there would read as a free request rather than an
        # unpriced one.
        def record_result(generation, trace_attributes)
          return unless trace_attributes

          handle_truncation(trace_attributes[:input], trace_attributes[:output], trace_attributes[:model])

          generation.model = trace_attributes[:model] if trace_attributes[:model]
          generation.usage_details = trace_attributes[:usage_details] if trace_attributes[:usage_details]
          generation.cost_details = trace_attributes[:cost_details] if trace_attributes[:cost_details]
          generation.input = trace_attributes[:input] if trace_attributes[:input]
          generation.output = trace_attributes[:output] if trace_attributes[:output]

          generation.update_trace(input: trace_attributes[:input], output: trace_attributes[:output])
        end

        # Recorded before the request is made so that a request which raises still
        # shows what was sent. Handlers whose input is not safe to record twice
        # (image generation sends base64 payloads that are replaced with media
        # references on success) pass no input and rely on the failure record alone.
        def record_input(generation, input)
          return if input.blank?

          generation.input = input
          generation.update_trace(input:)
        end

        # `session_id` and `tags` are only forwarded when set so that callers who
        # pass neither keep the existing propagation payload.
        def propagated_attributes(parameters, metadata)
          attributes = {
            user_id: parameters[:user_id] || NitroIntelligence.configuration.observability_user_id,
            metadata:,
          }
          attributes[:session_id] = parameters[:session_id] if parameters[:session_id].present?
          attributes[:tags] = parameters[:tags] if parameters[:tags].present?
          attributes
        end

        # Without this, a request that raises leaves an observation carrying only
        # its name and model - no input, no output, no indication anything went
        # wrong - because langfuse-rb ends the span in an `ensure` and never
        # records the exception.
        def observe_failures(generation)
          yield
        rescue => e
          record_failure(generation, e)
          raise
        end

        def record_failure(generation, error)
          generation.update(
            level: "ERROR",
            status_message: "#{error.class}: #{error.message}".truncate(MAX_STATUS_MESSAGE_LENGTH)
          )

          call_id = litellm_call_id(error)
          generation.metadata = { litellm_call_id: call_id } if call_id
        end

        def litellm_call_id(error)
          return nil unless error.respond_to?(:headers)

          error.headers&.[](LITELLM_CALL_ID_HEADER)
        end

        def handle_truncation(_input, output, model_name)
          model = NitroIntelligence.model_catalog.lookup_by_name(model_name)

          return unless model&.omit_output_fields

          model.omit_output_fields.each do |omit_output_field|
            last_key = omit_output_field.last
            parent_keys = omit_output_field[0...-1]
            parent = parent_keys.empty? ? output : output.dig(*parent_keys)

            parent[last_key] = "[Truncated...]" if parent.is_a?(Hash) && parent.key?(last_key)
          end
        end
      end
    end
  end
end
