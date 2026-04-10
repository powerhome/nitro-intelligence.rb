# This is an adaptation of https://github.com/simplepractice/langfuse-rb/blob/main/lib/langfuse/otel_setup.rb
# that lets users create multiple Langfuse clients in the same process.
# See also components/nitro_intelligence/lib/nitro_intelligence/langfuse_extension.rb
#
# The content of this file should eventually make its way upstream.
#
module NitroIntelligence
  class LangfuseTracerProvider
    def initialize(config)
      @tracer_provider = create_tracer_provider(config)
    end

    def tracer
      @tracer_provider.tracer("langfuse-rb", Langfuse::VERSION)
    end

    def shutdown(timeout: 30)
      @tracer_provider.shutdown(timeout:)
    end

  private

    def create_tracer_provider(config)
      raise ArgumentError, "training_async must be true" unless config.tracing_async

      exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: "#{config.base_url}/api/public/otel/v1/traces",
        headers: build_headers(config.public_key, config.secret_key),
        compression: "gzip"
      )

      processor = OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
        exporter,
        max_queue_size: config.batch_size * 2,
        schedule_delay: config.flush_interval * 1000,
        max_export_batch_size: config.batch_size
      )

      tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      tracer_provider.add_span_processor(processor)
      span_processor = Langfuse::SpanProcessor.new(config:)
      tracer_provider.add_span_processor(span_processor)

      OpenTelemetry.propagation = OpenTelemetry::Trace::Propagation::TraceContext::TextMapPropagator.new

      config.logger.info("Langfuse tracing initialized with OpenTelemetry (async mode)")

      tracer_provider
    end

    def build_headers(public_key, secret_key)
      credentials = "#{public_key}:#{secret_key}"
      encoded = Base64.strict_encode64(credentials)
      {
        "Authorization" => "Basic #{encoded}",
      }
    end
  end
end
