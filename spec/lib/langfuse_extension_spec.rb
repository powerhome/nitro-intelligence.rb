require "spec_helper"
require "nitro_intelligence/langfuse_extension"
require "nitro_intelligence/client/observers/langfuse_observer"
require "nitro_intelligence/client/handlers/base_handler"

RSpec.describe NitroIntelligence::LangfuseExtension do
  let(:packets) { [] }
  let(:exporter) { OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: "http://127.0.0.1:1", compression: "gzip") }
  let(:client) do
    described_class.new do |config|
      config.base_url = "http://127.0.0.1:1"
      config.public_key = "synthetic-public"
      config.secret_key = "synthetic-secret"
      config.tracing_async = true
      config.flush_interval = 3600
      config.logger = Logger.new(File::NULL)
    end
  end
  let(:observer) do
    NitroIntelligence::Client::Observers::LangfuseObserver.new(
      project_client: Struct.new(:observability_client).new(client)
    )
  end
  let(:seed) { "synthetic-root-seed" }
  let(:trace_id) { NitroIntelligence::Trace.create_id(seed:) }

  before do
    @original_propagation = OpenTelemetry.propagation
    # Intercept only the transport: real SDK spans pass through the OTLP protobuf encoder.
    allow(exporter).to receive(:send_bytes) do |bytes, **_kwargs|
      packets << bytes
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end
    allow(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new).and_return(exporter)
    allow(NitroIntelligence).to receive_messages(
      configuration: double("Configuration", observability_user_id: "synthetic-user", current_revision: "synthetic-revision"),
      environment: :test,
      model_catalog: double("ModelCatalog", lookup_by_name: nil)
    )
  end

  after do
    client.shutdown(timeout: 5)
    OpenTelemetry.propagation = @original_propagation
  end

  def emit(name, seed: nil)
    observer.observe(
      name,
      type: :generation, trace_name: "trace-#{name}", input: "input-#{name}",
      parameters: { trace_seed: seed, model: "synthetic-model", metadata: {}, session_id: "synthetic-session" }
    ) do |generation|
      yield(generation) if block_given?
      [:result, { model: "synthetic-model", input: "input-#{name}", output: "output-#{name}" }]
    end
  end

  def wire_spans
    provider = client.instance_variable_get(:@tracer_provider).instance_variable_get(:@tracer_provider)
    expect(provider.force_flush(timeout: 5)).to eq(OpenTelemetry::SDK::Trace::Export::SUCCESS)
    packets.flat_map do |bytes|
      request = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(bytes)
      request.resource_spans.flat_map { |resource| resource.scope_spans.flat_map { |scope| scope.spans.to_a } }
    end
  end

  def attributes(span)
    span.attributes.to_h { |attribute| [attribute.key, attribute.value.string_value] }
  end

  it "exports ordinary generations as roots with trace fields" do
    emit("ordinary")

    span = wire_spans.fetch(0)
    expect(span.parent_span_id).to be_empty
    expect(attributes(span)).to include(
      "langfuse.trace.name" => "trace-ordinary",
      "langfuse.release" => "synthetic-revision",
      "langfuse.trace.input" => '"input-ordinary"',
      "langfuse.trace.output" => '"output-ordinary"'
    )
  end

  it "exports repeated seeded generations as real roots in the same trace" do
    emit("first", seed:)
    emit("second", seed:)

    spans = wire_spans
    expect(spans.size).to eq(2)
    expect(spans.map { |span| span.trace_id.unpack1("H*") }).to eq([trace_id, trace_id])
    expect(spans.map(&:parent_span_id)).to eq(["", ""])
    expect(spans.map(&:span_id).uniq.size).to eq(2)
    spans.each do |span|
      # Cerebro's native trace IO aggregation selects parentless observations.
      expect(attributes(span)).to include(
        "langfuse.trace.name" => "trace-#{span.name}",
        "langfuse.release" => "synthetic-revision",
        "langfuse.trace.input" => "input-#{span.name}".to_json,
        "langfuse.trace.output" => "output-#{span.name}".to_json,
        "langfuse.observation.input" => "input-#{span.name}".to_json,
        "langfuse.observation.output" => "output-#{span.name}".to_json,
        "session.id" => "synthetic-session"
      )
    end
  end

  it "sends the exported seeded trace ID in the inference correlation header" do
    parameters = {}
    handler = NitroIntelligence::Client::Handlers::BaseHandler.new(client: nil)
    emit("seeded", seed:) do |generation|
      handler.send(:add_correlation_headers, parameters, trace_id: generation.trace_id)
    end

    expect(parameters.dig(:request_options, :extra_headers, "x-litellm-trace-id"))
      .to eq(wire_spans.fetch(0).trace_id.unpack1("H*"))
  end

  it "keeps an ordinary generation nested under an actual ambient observation" do
    client.observe("parent") { emit("child") }

    spans = wire_spans
    parent = spans.find { |span| span.name == "parent" }
    child = spans.find { |span| span.name == "child" }
    expect(parent.parent_span_id).to be_empty
    expect(child.trace_id).to eq(parent.trace_id)
    expect(child.parent_span_id).to eq(parent.span_id)
  end

  it "keeps an explicit seeded generation independent of the ambient parent" do
    client.observe("parent") { emit("seeded", seed:) }

    spans = wire_spans
    parent = spans.find { |span| span.name == "parent" }
    seeded = spans.find { |span| span.name == "seeded" }
    expect(seeded.parent_span_id).to be_empty
    expect(seeded.trace_id.unpack1("H*")).to eq(trace_id)
    expect(seeded.trace_id).not_to eq(parent.trace_id)
  end

  it "preserves an explicitly supplied parent span context" do
    parent_context = nil
    client.observe("parent") { parent_context = OpenTelemetry::Trace.current_span.context }
    client.start_observation("child", parent_span_context: parent_context).end

    spans = wire_spans
    parent = spans.find { |span| span.name == "parent" }
    child = spans.find { |span| span.name == "child" }
    expect(child.trace_id).to eq(parent.trace_id)
    expect(child.parent_span_id).to eq(parent.span_id)
  end

  it "rejects invalid trace IDs and conflicting explicit parent contexts" do
    expect { client.start_observation("invalid", trace_id: "0" * 32) }
      .to raise_error(ArgumentError, /Invalid trace_id/)
    expect { client.start_observation("conflict", trace_id:, parent_span_context: OpenTelemetry::Trace::SpanContext::INVALID) }
      .to raise_error(ArgumentError, "Cannot specify both trace_id and parent_span_context")
  end

  it "restores the ambient context when a seeded observation raises" do
    client.observe("parent") do
      parent = OpenTelemetry::Trace.current_span
      expect { client.observe("seeded", trace_id:) { raise "synthetic failure" } }.to raise_error("synthetic failure")
      expect(OpenTelemetry::Trace.current_span).to eq(parent)
      emit("child")
    end

    spans = wire_spans
    parent = spans.find { |span| span.name == "parent" }
    child = spans.find { |span| span.name == "child" }
    expect(child.parent_span_id).to eq(parent.span_id)
    expect(child.trace_id).to eq(parent.trace_id)
  end

  it "restores the context when seeded span creation raises" do
    tracer = client.instance_variable_get(:@tracer_provider).tracer
    allow(tracer).to receive(:start_span).and_call_original
    allow(tracer).to receive(:start_span).with("fails", anything).and_raise("creation failure")
    context = OpenTelemetry::Context.current

    expect { client.start_observation("fails", trace_id:) }.to raise_error("creation failure")
    expect(OpenTelemetry::Context.current).to eq(context)
    emit("ordinary")

    span = wire_spans.fetch(0)
    expect(span.trace_id.unpack1("H*")).not_to eq(trace_id)
    expect(span.parent_span_id).to be_empty
  end

  it "isolates seeded IDs across interleaved fibers and restores random roots" do
    tracer = client.instance_variable_get(:@tracer_provider).tracer
    allow(tracer).to receive(:start_span).and_wrap_original do |original, *args, **kwargs|
      Fiber.yield if args.first.start_with?("fiber-")
      original.call(*args, **kwargs)
    end
    other_id = NitroIntelligence::Trace.create_id(seed: "other-synthetic-seed")
    first = Fiber.new { client.observe("fiber-first", trace_id:) { :result } }
    second = Fiber.new { client.observe("fiber-second", trace_id: other_id) { :result } }
    first.resume
    second.resume
    first.resume
    second.resume
    emit("ordinary")

    spans = wire_spans
    expect(spans.find { |span| span.name == "fiber-first" }.trace_id.unpack1("H*")).to eq(trace_id)
    expect(spans.find { |span| span.name == "fiber-second" }.trace_id.unpack1("H*")).to eq(other_id)
    expect(spans.find { |span| span.name == "ordinary" }.trace_id.unpack1("H*")).not_to be_in([trace_id, other_id])
    expect(spans.map(&:parent_span_id)).to eq(["", "", ""])
  end
end
