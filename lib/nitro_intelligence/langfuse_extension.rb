# This is an adaptation of https://github.com/simplepractice/langfuse-rb/blob/main/lib/langfuse.rb
# that lets users set custom trace IDs and create multiple Langfuse clients in the same process.
#
# The content of this file should eventually make its way upstream. Setting a custom trace ID is
# already awaiting approval in https://github.com/simplepractice/langfuse-rb/pull/69.
#
module NitroIntelligence
  class LangfuseExtension
    attr_reader :config

    def initialize
      config = Langfuse::Config.new
      yield(config) if block_given?

      @config = config
      @client = Langfuse::Client.new(config)
      @tracer_provider = LangfuseTracerProvider.new(config)
    end

    def shutdown(timeout: 30)
      @client.shutdown
      @tracer_provider.shutdown(timeout:)
    end

    def create_score(name:, value:, id: nil, trace_id: nil, session_id: nil, observation_id: nil, comment: nil, # rubocop:disable Metrics/ParameterLists
                     metadata: nil, environment: nil, data_type: :numeric, dataset_run_id: nil, config_id: nil)
      @client.create_score(
        name:,
        value:,
        id:,
        trace_id:,
        session_id:,
        observation_id:,
        comment:,
        metadata:,
        environment:,
        data_type:,
        dataset_run_id:,
        config_id:
      )
    end

    def start_observation(name, attrs = {}, as_type: :span, parent_span_context: nil, start_time: nil,
                          skip_validation: false)
      type_str = as_type.to_s

      unless skip_validation || Langfuse.send(:valid_observation_type?, as_type)
        valid_types = Langfuse::OBSERVATION_TYPES.values.sort.join(", ")
        raise ArgumentError, "Invalid observation type: #{type_str}. Valid types: #{valid_types}"
      end

      otel_tracer = @tracer_provider.tracer
      otel_span = Langfuse.send(:create_otel_span,
                                name:,
                                start_time:,
                                parent_span_context:,
                                otel_tracer:)

      # Serialize attributes
      # Only set attributes if span is still recording (should always be true here, but guard for safety)
      if otel_span.recording?
        otel_attrs = Langfuse::OtelAttributes.create_observation_attributes(type_str, attrs.to_h, mask: nil)
        otel_attrs.each { |key, value| otel_span.set_attribute(key, value) }
      end

      # Wrap in appropriate class (attributes already set on span above — pass nil to avoid double-masking)
      observation = Langfuse.send(:wrap_otel_span, otel_span, type_str, otel_tracer)

      # Events auto-end immediately when created
      observation.end if type_str == Langfuse::OBSERVATION_TYPES[:event]

      observation
    end

    def observe(name, attrs = {}, as_type: :span, trace_id: nil, **kwargs, &block)
      # Merge positional attrs and keyword kwargs
      merged_attrs = attrs.to_h.merge(kwargs)
      unless trace_id.nil?
        unless valid_trace_id?(trace_id)
          raise ArgumentError, "#{trace_id} is not a valid 32 lowercase hex char Langfuse trace ID"
        end

        parent_span_context = create_span_context_with_trace_id(trace_id)
      end
      observation = start_observation(name, merged_attrs, as_type:, parent_span_context:)

      if block
        # Block-based API: auto-ends when block completes
        # Set context and execute block
        current_context = OpenTelemetry::Context.current
        begin
          result = OpenTelemetry::Context.with_current(
            OpenTelemetry::Trace.context_with_span(observation.otel_span, parent_context: current_context)
          ) do
            yield(observation)
          end
        ensure
          # Only end if not already ended (events auto-end in start_observation)
          observation.end unless as_type.to_s == Langfuse::OBSERVATION_TYPES[:event]
        end
        result
      else
        # Stateful API - return observation
        # Events already auto-ended in start_observation
        observation
      end
    end

  private

    def valid_trace_id?(trace_id)
      !!(trace_id =~ /^[0-9a-f]{32}$/)
    end

    def create_span_context_with_trace_id(trace_id_as_hex_str)
      trace_id_as_byte_str = [trace_id_as_hex_str].pack("H*")
      # NOTE: trace_flags must be SAMPLED or the trace will not appear in Langfuse.
      # The Python SDK does the same: https://github.com/langfuse/langfuse-python/blob/v4.0.0/langfuse/_client/client.py#L1568
      trace_flags = OpenTelemetry::Trace::TraceFlags::SAMPLED
      OpenTelemetry::Trace::SpanContext.new(
        trace_id: trace_id_as_byte_str,
        trace_flags:
      )
    end
  end
end
