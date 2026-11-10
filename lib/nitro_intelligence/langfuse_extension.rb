# This is an adaptation of https://github.com/simplepractice/langfuse-rb/blob/main/lib/langfuse.rb
# that lets users set custom trace IDs and create multiple Langfuse clients in the same process.
#
# The content of this file should eventually make its way upstream. Setting a custom trace ID is
# already awaiting approval in https://github.com/simplepractice/langfuse-rb/pull/69.
#
# Explicit trace IDs create real roots here while the upstream fix awaits approval:
# https://github.com/simplepractice/langfuse-rb/pull/128.
#

require "nitro_intelligence/langfuse_tracer_provider"

module NitroIntelligence
  # @api private
  class LangfuseExtension
    # Holds the client recording the {Observation} application code has open, so that observations
    # started inside it nest under it only when they are recorded in the same project.
    ACTIVE_OBSERVATION_KEY = OpenTelemetry::Context.create_key("nitro-intelligence-active-observation")

    # Holds the context the application had before it opened the trace it has open now.
    TRACE_BASE_KEY = OpenTelemetry::Context.create_key("nitro-intelligence-trace-base")

    # What a trace the application opens adds to the context, besides its active span.
    TRACE_KEYS = [*Langfuse::Propagation::CONTEXT_KEYS.values, ACTIVE_OBSERVATION_KEY, TRACE_BASE_KEY].freeze

    # Runs the block for a trace of its own. Inside a trace the application opened, the block runs
    # without that trace's active span and propagated attributes, as it would outside the trace:
    # `Langfuse.propagate_attributes` writes onto the active span and merges into what the context
    # already propagates, so a trace started inside another would otherwise change it and inherit
    # from it.
    def self.in_new_trace(&)
      context = OpenTelemetry::Context.current
      base = context.value(TRACE_BASE_KEY)
      unless base.nil?
        context = OpenTelemetry::Trace.context_with_span(OpenTelemetry::Trace.current_span(base),
                                                         parent_context: context)
        context = TRACE_KEYS.reduce(context) { |restored, key| restored.set_value(key, base.value(key)) }
      end

      OpenTelemetry::Context.with_current(context.set_value(TRACE_BASE_KEY, context), &)
    end

    attr_reader :config

    def initialize
      config = Langfuse::Config.new
      yield(config) if block_given?

      @config = config
      @client = Langfuse::Client.new(config)
      @tracer_provider = NitroIntelligence::LangfuseTracerProvider.new(config)
    end

    # @api private
    def flush(timeout: 30)
      @tracer_provider.force_flush(timeout:)
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

    # Whether application code has an observation open in this client, under which an observation
    # started without a trace ID or parent nests.
    def observing?
      active_observation_client.equal?(self)
    end

    # Runs the block with `observation` as the active span, so that observations this client starts
    # inside it, the gem's own included, nest under it.
    def within(observation, &)
      context = OpenTelemetry::Trace.context_with_span(observation.otel_span)
      context = context.set_value(ACTIVE_OBSERVATION_KEY, self)
      OpenTelemetry::Context.with_current(context, &)
    end

    def start_observation(name, attrs = {}, as_type: :span, trace_id: nil, parent_span_context: nil, start_time: nil, # rubocop:disable Metrics/ParameterLists
                          skip_validation: false)
      parent_span_context = Langfuse.send(:resolve_trace_context, trace_id, parent_span_context)
      type_str = as_type.to_s
      Langfuse.send(:validate_observation_type!, as_type, type_str) unless skip_validation

      otel_tracer = @tracer_provider.tracer
      otel_span = if trace_id
                    @tracer_provider.start_root_span(name, trace_id: parent_span_context.trace_id, start_time:)
                  else
                    Langfuse.send(:create_otel_span,
                                  name:,
                                  start_time:,
                                  parent_span_context:,
                                  otel_tracer:)
                  end

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

  private

    def active_observation_client
      OpenTelemetry::Context.value(ACTIVE_OBSERVATION_KEY)
    end
  end
end
