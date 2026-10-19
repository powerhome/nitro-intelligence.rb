# This is an adaptation of https://github.com/simplepractice/langfuse-rb/blob/main/lib/langfuse/otel_setup.rb
# that lets users create multiple Langfuse clients in the same process.
# See also components/nitro_intelligence/lib/nitro_intelligence/langfuse_extension.rb
#
# The content of this file should eventually make its way upstream.
#
module NitroIntelligence
  class LangfuseTracerProvider
    attr_reader :id_generator

    def initialize(config)
      @id_generator = Langfuse::RootSpanIdGenerator.new
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

      tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(id_generator: @id_generator)
      tracer_provider.add_span_processor(Langfuse::SpanProcessor.new(config:, exporter:, metrics_reporter: nil))

      OpenTelemetry.propagation = OpenTelemetry::Trace::Propagation::TraceContext::TextMapPropagator.new

      config.logger.info("Langfuse tracing initialized with OpenTelemetry (async mode)")

      tracer_provider
    end

    def build_headers(public_key, secret_key)
      credentials = "#{public_key}:#{secret_key}"
      encoded = Base64.strict_encode64(credentials)
      {
        "Authorization" => "Basic #{encoded}",
        "x-langfuse-ingestion-version" => "4",
      }
    end
  end
end
