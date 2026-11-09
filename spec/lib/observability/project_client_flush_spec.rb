require "spec_helper"
require "nitro_intelligence/observability/project_client_registry"
require "nitro_intelligence/client/observers/langfuse_observer"

RSpec.describe NitroIntelligence::Observability::ProjectClient, "#flush" do
  let(:packets) { [] }
  let(:exporter) { OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: "http://127.0.0.1:1", compression: "gzip") }
  let(:registry) { NitroIntelligence::Observability::ProjectClientRegistry.new(base_url: "http://127.0.0.1:1") }
  let(:project) do
    instance_double(NitroIntelligence::Observability::Project,
                    public_key: "synthetic-public", secret_key: "synthetic-secret", mask_content?: false)
  end
  let(:client) { registry.fetch("flush-project") }
  let(:observer) { NitroIntelligence::Client::Observers::LangfuseObserver.new(project_client: client) }

  before do
    @original_propagation = OpenTelemetry.propagation
    allow(NitroIntelligence::Observability::Project).to receive(:find_by_slug).and_return(project)
    allow(Langfuse::Config).to receive(:new).and_wrap_original do |original|
      original.call.tap { |config| config.logger = Logger.new(File::NULL) }
    end
    # Real spans, batch processor and OTLP encoding; intercept only transport.
    allow(exporter).to receive(:send_bytes) do |bytes, **_kwargs|
      packets << bytes
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end
    allow(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new).and_return(exporter)
  end

  after do
    registry.shutdown_all
    OpenTelemetry.propagation = @original_propagation
  end

  def exported_spans
    packets.flat_map do |bytes|
      request = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(bytes)
      request.resource_spans.flat_map { |resource| resource.scope_spans.flat_map { |scope| scope.spans.to_a } }
    end
  end

  def emit(name)
    client.observability_client.observe(name) { |observation| observation.update(output: name) }
  end

  it "exports completed roots and SDK-generated children on the same project client" do
    client.observability_client.observe("experiment-item") do
      observer.observe("generation", type: :generation, trace_name: "experiment", parameters: { metadata: {} }) do
        [:result, { output: "generated image" }]
      end
    end

    expect(packets).to be_empty
    expect(client.flush).to be(true)
    root = exported_spans.find { |span| span.name == "experiment-item" }
    child = exported_spans.find { |span| span.name == "generation" }
    expect(exported_spans.size).to eq(2)
    expect(child.trace_id).to eq(root.trace_id)
    expect(child.parent_span_id).to eq(root.span_id)
  end

  it "exports more observations through the same cached client after a flush" do
    emit("first-job")
    expect(client.flush).to be(true)
    expect(registry.fetch("flush-project")).to equal(client)

    emit("next-job")
    expect(client.flush).to be(true)
    expect(exported_spans.map(&:name)).to eq(%w[first-job next-job])
  end

  it "flushes only the requested project's observations" do
    other = registry.fetch("other-project")
    other.observability_client.observe("other-project-job") { nil }
    emit("this-project-job")

    expect(client.flush).to be(true)
    expect(exported_spans.map(&:name)).to eq(["this-project-job"])
    expect(other.flush).to be(true)
    expect(exported_spans.map(&:name)).to eq(%w[this-project-job other-project-job])
  end

  it "leaves the score client and exporter running without flushing scores" do
    score_client = client.observability_client.instance_variable_get(:@client)
    allow(score_client).to receive(:shutdown).and_call_original
    allow(score_client).to receive(:flush_scores).and_call_original
    allow(exporter).to receive(:shutdown).and_call_original

    expect(client.flush).to be(true)
    expect(score_client).not_to have_received(:shutdown)
    expect(score_client).not_to have_received(:flush_scores)
    expect(exporter).not_to have_received(:shutdown)
  end

  it "leaves active observations recording until they are ended" do
    active = client.observability_client.start_observation("active-job")
    emit("completed-job")

    expect(client.flush).to be(true)
    expect(exported_spans.map(&:name)).to eq(["completed-job"])
    expect(active.otel_span).to be_recording

    active.end
    expect(client.flush).to be(true)
    expect(exported_spans.map(&:name)).to eq(%w[completed-job active-job])
  end

  it "allows overlapping jobs to record while a flush is exporting" do
    exporting = Queue.new
    resume_export = Queue.new
    allow(exporter).to receive(:send_bytes).and_wrap_original do |_original, bytes, **_kwargs|
      if packets.empty?
        exporting << true
        resume_export.pop
      end
      packets << bytes
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end

    emit("first-job")
    flushing = Thread.new { client.flush }
    expect(exporting.pop(timeout: 5)).to be(true)
    emit("overlapping-job")
    resume_export << true
    expect(flushing.join(5)&.value).to be(true)

    expect(client.flush).to be(true)
    expect(exported_spans.map(&:name)).to eq(%w[first-job overlapping-job])
  ensure
    resume_export << true
    flushing&.join(5)
  end

  it "succeeds when there are no completed observations to export" do
    expect(client.flush).to be(true)
    expect(packets).to be_empty
  end

  it "reports an export failure" do
    allow(exporter).to receive(:send_bytes).and_return(OpenTelemetry::SDK::Trace::Export::FAILURE)
    allow(OpenTelemetry).to receive(:handle_error)
    emit("failed-export")

    expect(client.flush).to be(false)
  end

  it "reports an exporter timeout" do
    allow(exporter).to receive(:send_bytes).and_return(OpenTelemetry::SDK::Trace::Export::TIMEOUT)
    allow(OpenTelemetry).to receive(:handle_error)
    emit("timed-out-export")

    expect(client.flush).to be(false)
  end

  it "reports a transport exception as an export failure" do
    allow(exporter).to receive(:send_bytes).and_raise(IOError, "export connection closed")
    allow(OpenTelemetry).to receive(:handle_error)
    emit("failed-connection")

    expect(client.flush).to be(false)
  end

  it "reports an exhausted timeout without stopping subsequent exports" do
    emit("pending-export")

    expect(client.flush(timeout: 0)).to be(false)
    expect(packets).to be_empty
    expect(client.flush).to be(true)
    expect(exported_spans.map(&:name)).to eq(["pending-export"])
  end

  context "with an automatic export in flight" do
    let(:export_started) { Queue.new }
    let(:release_export) { Queue.new }
    let(:flush_started) { Queue.new }
    let(:flush_results) { Queue.new }
    let(:flush_threads) { [] }
    let(:first_export_result) { OpenTelemetry::SDK::Trace::Export::SUCCESS }

    before do
      allow(NitroIntelligence::LangfuseExtension).to receive(:new).and_wrap_original do |original, &configure|
        original.call do |config|
          configure.call(config)
          config.flush_interval = 0.01
          config.batch_size = 2
        end
      end
      allow(OpenTelemetry).to receive(:handle_error)
      allow(exporter).to receive(:send_bytes) do |bytes, **_kwargs|
        packets << bytes
        export_started << true
        if packets.one?
          raise "Test did not release the export" unless release_export.pop(timeout: 5)

          first_export_result
        else
          OpenTelemetry::SDK::Trace::Export::SUCCESS
        end
      end
      emit("automatic-export")
      expect(export_started.pop(timeout: 5)).to be(true)
    end

    after do
      release_export << true
      flush_threads.each { |thread| thread.join(5) }
    end

    def start_flush(timeout: 2)
      flush_threads << Thread.new do
        flush_started << true
        flush_results << client.flush(timeout:)
      end
      expect(flush_started.pop(timeout: 5)).to be(true)
    end

    def start_shutdown
      stopped = Queue.new
      provider = client.observability_client.instance_variable_get(:@tracer_provider)
      worker = provider.instance_variable_get(:@batch_processor).instance_variable_get(:@thread)
      # Shutdown sets its stopped flag before joining the blocked export worker.
      allow(worker).to receive(:join).and_wrap_original do |original, *args|
        stopped << true
        original.call(*args)
      end
      allow(OpenTelemetry.logger).to receive(:warn)
      thread = Thread.new { registry.shutdown_all }
      flush_threads << thread
      expect(stopped.pop(timeout: 5)).to be(true)
      thread
    end

    it "waits for the in-flight export even when the buffer is empty" do
      start_flush
      expect(flush_results.pop(timeout: 0.05)).to be_nil

      release_export << true
      expect(flush_results.pop(timeout: 5)).to be(true)
    end

    it "also drains buffered batches and permits new observations while waiting" do
      start_flush
      emit("queued-1")
      emit("queued-2")
      emit("queued-3")
      active = client.observability_client.start_observation("still-active")
      expect(flush_results.pop(timeout: 0.05)).to be_nil

      release_export << true
      expect(flush_results.pop(timeout: 5)).to be(true)
      expect(exported_spans.map(&:name)).to eq(%w[automatic-export queued-1 queued-2 queued-3])
      expect(active.otel_span).to be_recording

      active.end
      expect(client.flush).to be(true)
      expect(exported_spans.last.name).to eq("still-active")
    end

    it "times out without cancelling the in-flight export or stopping the client" do
      start_flush(timeout: 0.05)
      expect(flush_results.pop(timeout: 1)).to be(false)

      emit("next-job")
      release_export << true
      expect(client.flush).to be(true)
      expect(exported_spans.map(&:name)).to eq(%w[automatic-export next-job])
    end

    it "gives concurrent flush callers independent waiting deadlines" do
      start_flush
      start_flush(timeout: 0.05)
      expect(flush_results.pop(timeout: 1)).to be(false)
      expect(flush_results.pop(timeout: 0.05)).to be_nil

      release_export << true
      expect(flush_results.pop(timeout: 5)).to be(true)
    end

    it "rejects flush during shutdown even when the buffer is empty" do
      start_shutdown
      start_flush(timeout: 0.05)

      expect(flush_results.pop(timeout: 1)).to be(false)
    end

    it "rejects flush promptly while shutdown drains queued and in-flight exports" do
      emit("queued-for-shutdown")
      shutting_down = start_shutdown
      start_flush(timeout: 0.05)
      expect(flush_results.pop(timeout: 1)).to be(false)

      release_export << true
      expect(shutting_down.join(5)).to eq(shutting_down)
      expect(exported_spans.map(&:name)).to eq(%w[automatic-export queued-for-shutdown])
      expect(client.flush).to be(false)
    end

    it "wakes an already waiting flush with failure when shutdown starts" do
      start_flush
      expect(flush_results.pop(timeout: 0.05)).to be_nil
      start_shutdown

      expect(flush_results.pop(timeout: 1)).to be(false)
    end

    context "when the in-flight export fails" do
      let(:first_export_result) { OpenTelemetry::SDK::Trace::Export::FAILURE }

      it "reports its failure to every flush already waiting" do
        start_flush
        start_flush
        expect(flush_results.pop(timeout: 0.05)).to be_nil

        release_export << true
        expect(flush_results.pop(timeout: 5)).to be(false)
        expect(flush_results.pop(timeout: 5)).to be(false)

        emit("later-success")
        expect(client.flush).to be(true)
        expect(exported_spans.last.name).to eq("later-success")
      end

      it "reports a failed in-flight export to a new flush after another times out" do
        start_flush(timeout: 0.05)
        expect(flush_results.pop(timeout: 1)).to be(false)

        start_flush
        expect(flush_results.pop(timeout: 0.05)).to be_nil
        release_export << true
        expect(flush_results.pop(timeout: 5)).to be(false)
        expect(client.flush).to be(true)
      end

      it "does not report a background failure that finished before flush was called" do
        release_export << true
        emit("success-after-failure")
        # Starting the next batch proves that the failed batch finished processing.
        expect(export_started.pop(timeout: 5)).to be(true)

        expect(client.flush).to be(true)
      end

      it "does not retain failures that finish after a flush has timed out" do
        start_flush(timeout: 0.05)
        expect(flush_results.pop(timeout: 1)).to be(false)
        release_export << true
        emit("success-after-timeout")
        expect(export_started.pop(timeout: 5)).to be(true)

        expect(client.flush).to be(true)
      end
    end

    it "reports observations dropped when the buffer fills while flush is waiting" do
      start_flush
      expect(flush_results.pop(timeout: 0.05)).to be_nil
      5.times { |index| emit("queued-#{index}") }
      release_export << true

      expect(flush_results.pop(timeout: 5)).to be(false)
      expect(exported_spans.map(&:name)).to eq(%w[automatic-export queued-1 queued-2 queued-3 queued-4])
      expect(client.flush).to be(true)
    end
  end
end
