require "spec_helper"
require "nitro_intelligence/tracer"

RSpec.describe NitroIntelligence::Tracer do
  let(:packets) { [] }
  let(:exporter) { OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: "http://127.0.0.1:1", compression: "gzip") }
  let(:mask_content) { false }
  let(:project_clients) do
    %w[synthetic-project other-project].to_h do |slug|
      observability_client = NitroIntelligence::LangfuseExtension.new do |config|
        config.base_url = "http://127.0.0.1:1"
        config.public_key = "#{slug}-public"
        config.secret_key = "#{slug}-secret"
        config.flush_interval = 3600
        config.logger = Logger.new(File::NULL)
      end
      project = NitroIntelligence::Observability::Project.new(
        slug:, id: slug, public_key: "#{slug}-public", secret_key: "#{slug}-secret", mask_content:
      )
      [slug, NitroIntelligence::Observability::ProjectClient.new(project:, observability_client:)]
    end
  end
  let(:registry) { double("ProjectClientRegistry") }
  let(:tracer) { described_class.new(observability_project_slug: "synthetic-project") }
  let(:project_client) { project_clients.fetch("synthetic-project") }
  let(:observer) { NitroIntelligence::Client::Observers::LangfuseObserver.new(project_client:) }

  before do
    @original_propagation = OpenTelemetry.propagation
    # Intercept only the transport: real SDK spans pass through the OTLP protobuf encoder.
    allow(exporter).to receive(:send_bytes) do |bytes, **_kwargs|
      packets << bytes
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end
    allow(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new).and_return(exporter)
    allow(registry).to receive(:fetch) { |slug| project_clients.fetch(slug) }
    allow(NitroIntelligence.configuration).to receive_messages(
      observability_user_id: "synthetic-app", current_revision: "synthetic-revision"
    )
    allow(NitroIntelligence).to receive_messages(
      project_client_registry: registry,
      environment: :test,
      model_catalog: double("ModelCatalog", lookup_by_name: nil)
    )
  end

  after do
    project_clients.each_value(&:shutdown)
    OpenTelemetry.propagation = @original_propagation
  end

  # A request the gem makes, as its observed handlers make it.
  def request(name, observer: self.observer, **parameters)
    observer.observe(
      name,
      type: :generation, trace_name: "request-#{name}", input: "input-#{name}",
      parameters: { model: "synthetic-model", metadata: { request: name }, **parameters }
    ) { [:result, { model: "synthetic-model", input: "input-#{name}", output: "output-#{name}" }] }
  end

  def wire_spans(slug = "synthetic-project")
    tracer_provider = project_clients.fetch(slug).observability_client.instance_variable_get(:@tracer_provider)
    expect(tracer_provider.instance_variable_get(:@tracer_provider).force_flush(timeout: 5))
      .to eq(OpenTelemetry::SDK::Trace::Export::SUCCESS)
    packets.flat_map do |bytes|
      request = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(bytes)
      request.resource_spans.flat_map { |resource| resource.scope_spans.flat_map { |scope| scope.spans.to_a } }
    end
  end

  def span(spans, name)
    spans.find { |candidate| candidate.name == name }
  end

  def attributes(span)
    span.attributes.to_h { |attribute| [attribute.key, attribute.value.string_value] }
  end

  it "records application steps and the gem's requests in one trace" do
    result = tracer.trace("search", input: { question: "where?" }, user_id: "user-1", session_id: "session-1",
                                    tags: ["page-finder"], metadata: { feature: "page-finder" }) do |trace|
      request("embed")
      trace.observe("elasticsearch", as_type: :retriever, input: { k: 50 }) do |step|
        step.output = %w[a b]
        request("rerank")
      end
      trace.event("shown", output: %w[b])
      trace.output = %w[b]
      :found
    end

    expect(result).to eq(:found)
    spans = wire_spans
    root = span(spans, "search")
    retriever = span(spans, "elasticsearch")
    expect(spans.map(&:trace_id).uniq).to eq([root.trace_id])
    expect(root.parent_span_id).to be_empty
    expect(span(spans, "embed").parent_span_id).to eq(root.span_id)
    expect(retriever.parent_span_id).to eq(root.span_id)
    expect(span(spans, "rerank").parent_span_id).to eq(retriever.span_id)
    expect(span(spans, "shown").parent_span_id).to eq(root.span_id)

    expect(attributes(root)).to include(
      "langfuse.trace.name" => "search",
      "langfuse.release" => "synthetic-revision",
      "langfuse.environment" => "test",
      "langfuse.trace.input" => { question: "where?" }.to_json,
      "langfuse.trace.output" => %w[b].to_json,
      "langfuse.observation.output" => %w[b].to_json,
      "user.id" => "user-1",
      "session.id" => "session-1",
      "langfuse.trace.metadata.feature" => "page-finder"
    )
    expect(attributes(retriever)).to include(
      "langfuse.observation.type" => "retriever",
      "langfuse.observation.input" => { k: 50 }.to_json,
      "langfuse.observation.output" => %w[a b].to_json,
      "langfuse.environment" => "test"
    )
    expect(attributes(span(spans, "shown"))).to include("langfuse.observation.type" => "event")
  end

  it "leaves the trace's own attributes to the application inside its trace" do
    tracer.trace("search", user_id: "user-1") do
      request("embed", user_id: "someone-else", session_id: "other-session")
    end

    spans = wire_spans
    nested = attributes(span(spans, "embed"))
    expect(nested).to include(
      "user.id" => "user-1",
      "langfuse.observation.input" => "input-embed".to_json,
      "langfuse.observation.output" => "output-embed".to_json,
      "langfuse.observation.metadata.request" => "embed"
    )
    expect(nested.keys).not_to include("langfuse.trace.name", "langfuse.trace.input", "langfuse.trace.output",
                                       "session.id")
    expect(attributes(span(spans, "search"))).not_to include("langfuse.trace.metadata.request")
  end

  it "defaults the trace's user to observability_user_id" do
    tracer.trace("search") { nil }

    expect(attributes(wire_spans.fetch(0))).to include("user.id" => "synthetic-app")
  end

  it "gives a seeded trace the seed's ID" do
    trace_id = tracer.trace("search", trace_seed: "search-1", &:trace_id)

    expect(trace_id).to eq(NitroIntelligence::Trace.create_id(seed: "search-1"))
    expect(wire_spans.fetch(0).trace_id.unpack1("H*")).to eq(trace_id)
  end

  it "starts a trace of its own inside another" do
    tracer.trace("outer") { tracer.trace("inner") { nil } }

    spans = wire_spans
    expect(span(spans, "inner").parent_span_id).to be_empty
    expect(span(spans, "inner").trace_id).not_to eq(span(spans, "outer").trace_id)
  end

  it "keeps a seeded request in its own trace" do
    tracer.trace("search") { request("seeded", trace_seed: "document-1") }

    seeded = span(wire_spans, "seeded")
    expect(seeded.parent_span_id).to be_empty
    expect(seeded.trace_id.unpack1("H*")).to eq(NitroIntelligence::Trace.create_id(seed: "document-1"))
    expect(attributes(seeded)).to include("langfuse.trace.name" => "request-seeded")
  end

  it "records a request to another project as a trace of its own there" do
    other = NitroIntelligence::Client::Observers::LangfuseObserver.new(project_client: project_clients.fetch("other-project"))
    tracer.trace("search") { request("elsewhere", observer: other) }

    elsewhere = span(wire_spans("other-project"), "elsewhere")
    expect(elsewhere.parent_span_id).to be_empty
    expect(elsewhere.trace_id).not_to eq(span(wire_spans, "search").trace_id)
    expect(attributes(elsewhere)).to include("langfuse.trace.name" => "request-elsewhere")
  end

  it "records a failure on the step and the trace, and re-raises it" do
    expect do
      tracer.trace("search") { |trace| trace.observe("elasticsearch") { raise ArgumentError, "bad query" } }
    end.to raise_error(ArgumentError, "bad query")

    spans = wire_spans
    expect(attributes(span(spans, "elasticsearch"))).to include(
      "langfuse.observation.level" => "ERROR", "langfuse.observation.status_message" => "ArgumentError: bad query"
    )
    expect(attributes(span(spans, "search"))).to include("langfuse.observation.level" => "ERROR")
  end

  it "rejects an observation type Langfuse does not have, and a missing block" do
    expect { tracer.trace("search", as_type: :reranker) { nil } }.to raise_error(ArgumentError, /as_type/)
    expect { tracer.trace("search") }.to raise_error(ArgumentError, /block/)
    expect { tracer.trace("search") { |trace| trace.observe("step", as_type: :event) { nil } } }
      .to raise_error(ArgumentError, /as_type/)
  end

  context "when the project masks content" do
    let(:mask_content) { true }

    it "masks what the application records, and the message of a failure" do
      expect do
        tracer.trace("search", input: "secret question", metadata: { feature: "page-finder" }) do |trace|
          trace.event("shown", input: "secret", output: "secret")
          trace.observe("elasticsearch", input: "secret") { raise ArgumentError, "secret" }
        end
      end.to raise_error(ArgumentError)

      spans = wire_spans
      expect(attributes(span(spans, "search"))).to include(
        "langfuse.trace.input" => '"[masked]"',
        "langfuse.observation.input" => '"[masked]"',
        "langfuse.trace.metadata.feature" => "page-finder"
      )
      expect(attributes(span(spans, "shown"))).to include(
        "langfuse.observation.input" => '"[masked]"', "langfuse.observation.output" => '"[masked]"'
      )
      expect(attributes(span(spans, "elasticsearch"))).to include(
        "langfuse.observation.input" => '"[masked]"', "langfuse.observation.status_message" => "ArgumentError"
      )
    end
  end
end
