# This is an adaptation of https://github.com/simplepractice/langfuse-rb/blob/main/lib/langfuse.rb
# that lets users set custom trace IDs and create multiple Langfuse clients in the same process.
#
# The content of this file should eventually make its way upstream. Setting a custom trace ID is
# already awaiting approval in https://github.com/simplepractice/langfuse-rb/pull/69.
#

require "nitro_intelligence/langfuse_tracer_provider"

module NitroIntelligence
  class LangfuseExtension
    attr_reader :config

    def initialize
      config = Langfuse::Config.new
      yield(config) if block_given?

      @config = config
      @client = Langfuse::Client.new(config)
      @tracer_provider = NitroIntelligence::LangfuseTracerProvider.new(config)
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

    def start_observation(name, attrs = {}, as_type: :span, trace_id: nil, parent_span_context: nil, start_time: nil, # rubocop:disable Metrics/ParameterLists
                          skip_validation: false)
      parent_span_context = Langfuse.send(:resolve_trace_context, trace_id, parent_span_context)
      type_str = as_type.to_s
      Langfuse.send(:validate_observation_type!, as_type, type_str) unless skip_validation

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
      merged_attrs = attrs.to_h.merge(kwargs)
      observation = start_observation(name, merged_attrs, as_type:, trace_id:)
      return observation unless block

      observation.send(:run_in_context, &block)
    end
  end
end
