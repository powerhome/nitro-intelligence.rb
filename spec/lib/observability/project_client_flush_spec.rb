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

  it "succeeds with a zero timeout when the running client has no pending exports" do
    expect(client.flush(timeout: 0)).to be(true)
    expect(packets).to be_empty

    emit("after-idle-flush")
    expect(client.flush).to be(true)
    expect(exported_spans.map(&:name)).to eq(["after-idle-flush"])
    expect(client.flush(timeout: 0)).to be(true)
  end

  it "succeeds with a zero timeout without ending active observations" do
    active = client.observability_client.start_observation("still-recording")

    expect(client.flush(timeout: 0)).to be(true)
    expect(active.otel_span).to be_recording
    expect(packets).to be_empty
  ensure
    active&.end
  end

  it "rejects a zero timeout flush on a stopped client with no pending exports" do
    allow(OpenTelemetry.logger).to receive(:warn)
    client.shutdown

    expect(client.flush(timeout: 0)).to be(false)
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

  it "reports a zero timeout with queued observations without stopping subsequent exports" do
    emit("pending-export")

    expect(client.flush(timeout: 0)).to be(false)
    expect(packets).to be_empty
    expect(client.flush).to be(true)
    expect(exported_spans.map(&:name)).to eq(["pending-export"])
  end

  context "when starting the export worker fails" do
    let(:startup_error) { ThreadError.new("can't create Thread: Resource temporarily unavailable") }
    let(:start_thread_on_boot) { true }
    let(:metrics_reporter) { OpenTelemetry::SDK::Trace::Export::MetricsReporter }
    let(:processor) do
      client.observability_client.instance_variable_get(:@tracer_provider).instance_variable_get(:@batch_processor)
    end

    before do
      allow(NitroIntelligence::Observability::BatchSpanProcessor).to receive(:new).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs, start_thread_on_boot:)
      end
      processor.instance_variable_get(:@thread)&.kill&.join
      allow(Thread).to receive(:new).and_raise(startup_error)
      allow(OpenTelemetry).to receive(:handle_error)
      allow(metrics_reporter).to receive(:add_to_counter).and_call_original
      emit("queued-before-startup-failure")
    end

    it "returns false and reports a failed worker restart" do
      expect(client.flush).to be(false)
      expect(packets).to be_empty
      expect(OpenTelemetry).to have_received(:handle_error)
        .with(exception: startup_error, message: /BatchSpanProcessor/).once
      expect(metrics_reporter).to have_received(:add_to_counter)
        .with("otel.bsp.error", labels: { "reason" => "ThreadError" }).once
    end

    it "keeps queued observations and lets a later flush restart the worker" do
      expect(client.flush).to be(false)
      allow(Thread).to receive(:new).and_call_original
      emit("queued-after-startup-failure")

      expect(client.flush).to be(true)
      expect(exported_spans.map(&:name)).to eq(%w[queued-before-startup-failure queued-after-startup-failure])
    end

    context "when the worker has never started" do
      let(:start_thread_on_boot) { false }

      it "returns false instead of raising" do
        expect(client.flush).to be(false)
        expect(packets).to be_empty
      end
    end

    it "attempts startup once and reports the failure when flush detects a fork" do
      # Simulate a changed PID after the original worker has stopped.
      processor.instance_variable_set(:@pid, -1)

      expect(client.flush).to be(false)
      expect(Thread).to have_received(:new).once
      expect(OpenTelemetry).to have_received(:handle_error)
        .with(exception: startup_error, message: /BatchSpanProcessor/).once
      expect(metrics_reporter).to have_received(:add_to_counter)
        .with("otel.bsp.error", labels: { "reason" => "ThreadError" }).once
    end
  end

  context "with an automatic export in flight" do
    let(:export_started) { Queue.new }
    let(:release_export) { Queue.new }
    let(:flush_results) { Queue.new }
    let(:flush_threads) { [] }
    let(:first_export_result) { OpenTelemetry::SDK::Trace::Export::SUCCESS }
    let(:later_export_results) { nil }
    let(:processor) do
      client.observability_client.instance_variable_get(:@tracer_provider).instance_variable_get(:@batch_processor)
    end

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
          next_export_result
        end
      end
      emit("automatic-export")
      expect(export_started.pop(timeout: 5)).to be(true)
      # Signal only once flush has captured its work and is about to release the
      # queue lock. Later observations can then be added without a timing race.
      allow(processor.instance_variable_get(:@flush_condition)).to receive(:wait).and_wrap_original do |original, *args|
        Thread.current[:flush_started]&.push(true)
        original.call(*args)
      end
    end

    after do
      release_export << true
      later_export_results&.close
      flush_threads.each { |thread| thread.join(5) }
    end

    def next_export_result
      return OpenTelemetry::SDK::Trace::Export::SUCCESS unless later_export_results

      result = later_export_results.pop(timeout: 5)
      raise "Test did not release the export" if result.nil? && !later_export_results.closed?

      result || OpenTelemetry::SDK::Trace::Export::SUCCESS
    end

    def start_flush(timeout: 2)
      started = Queue.new
      thread = Thread.new do
        Thread.current[:flush_started] = started
        result = client.flush(timeout:)
        flush_results << result
        result
      ensure
        Thread.current[:flush_started] = nil
        started << true
      end
      flush_threads << thread
      expect(started.pop(timeout: 5)).to be(true)
      thread
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

    def pause_flush_on_wakeup(paused, resume)
      condition = processor.instance_variable_get(:@flush_condition)
      allow(condition).to receive(:wait).and_wrap_original do |original, mutex, timeout|
        Thread.current[:flush_started]&.push(true)
        original.call(mutex, timeout)
        # Let other threads progress before this caller checks its completed result.
        mutex.unlock
        begin
          paused << true
          resume.pop(timeout: 5)
        ensure
          mutex.lock
        end
      end
    end

    it "waits for the in-flight export even when the buffer is empty" do
      start_flush
      expect(flush_results.pop(timeout: 0.05)).to be_nil

      release_export << true
      expect(flush_results.pop(timeout: 5)).to be(true)
    end

    it "reports a zero timeout while an export is in flight even when the buffer is empty" do
      start_flush(timeout: 0)
      expect(flush_results.pop(timeout: 1)).to be(false)

      release_export << true
      expect(client.flush).to be(true)
      expect(client.flush(timeout: 0)).to be(true)
    end

    it "also drains batches queued before the call without ending active observations" do
      emit("queued-1")
      emit("queued-2")
      emit("queued-3")
      active = client.observability_client.start_observation("still-active")
      start_flush
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
      expect(processor.instance_variable_get(:@flush_waiters)).to be_empty
    end

    it "rejects flush during shutdown even when the buffer is empty" do
      start_shutdown
      expect(client.flush(timeout: 0)).to be(false)
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

    it "keeps a completed flush's success when its caller resumes after the deadline" do
      paused = Queue.new
      resume = Queue.new
      pause_flush_on_wakeup(paused, resume)
      now = 0.0
      # Advance only the flush caller's clock after its captured export completes.
      allow(OpenTelemetry::Common::Utilities).to receive(:timeout_timestamp).and_wrap_original do |original|
        Thread.current[:flush_started] ? now : original.call
      end
      flushing = start_flush(timeout: 30)
      release_export << true
      expect(paused.pop(timeout: 5)).to be(true)
      now = 31.0
      resume << true

      expect(flushing.join(5)&.value).to be(true)
    ensure
      resume&.close
    end

    it "keeps a completed flush's success when shutdown starts before its caller resumes" do
      paused = Queue.new
      resume = Queue.new
      pause_flush_on_wakeup(paused, resume)
      flushing = start_flush
      release_export << true
      expect(paused.pop(timeout: 5)).to be(true)
      shutting_down = start_shutdown
      expect(shutting_down.join(5)).to eq(shutting_down)
      resume << true

      expect(flushing.join(5)&.value).to be(true)
    ensure
      resume&.close
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

    it "reports captured observations dropped when the buffer fills while flush is waiting" do
      emit("captured-before-flush")
      start_flush
      5.times { |index| emit("queued-#{index}") }
      release_export << true

      expect(flush_results.pop(timeout: 5)).to be(false)
      expect(exported_spans.map(&:name)).to eq(%w[automatic-export queued-1 queued-2 queued-3 queued-4])
      expect(client.flush).to be(true)
    end

    it "ignores dropped observations that were added after the call" do
      start_flush
      5.times { |index| emit("queued-#{index}") }
      release_export << true

      expect(flush_results.pop(timeout: 5)).to be(true)
    end

    it "reports dropped observations only to flushes that captured them" do
      earlier = start_flush
      emit("captured-by-later-flush")
      later = start_flush
      5.times { |index| emit("queued-#{index}") }
      release_export << true

      expect(earlier.join(5)&.value).to be(true)
      expect(later.join(5)&.value).to be(false)
    end

    context "with later exports controlled independently" do
      let(:later_export_results) { Queue.new }

      it "uses flush boundaries registered while the worker is waking" do
        sleeping = Queue.new
        woken = Queue.new
        resume_worker = Queue.new
        allow(processor.instance_variable_get(:@condition)).to receive(:wait).and_wrap_original do |original, mutex, timeout|
          sleeping << true
          original.call(mutex, timeout)
          # Allow both flush calls to capture their work before the worker resumes.
          mutex.unlock
          begin
            woken << true
            resume_worker.pop(timeout: 5)
          ensure
            mutex.lock
          end
        end
        release_export << true
        expect(sleeping.pop(timeout: 5)).to be(true)
        emit("first-job")
        earlier = start_flush
        expect(woken.pop(timeout: 5)).to be(true)
        emit("second-job")
        later = start_flush
        resume_worker << true

        expect(export_started.pop(timeout: 5)).to be(true)
        expect(exported_spans.map(&:name)).to eq(%w[automatic-export first-job])
        later_export_results << OpenTelemetry::SDK::Trace::Export::SUCCESS
        expect(earlier.join(1)&.value).to be(true)
        expect(export_started.pop(timeout: 5)).to be(true)
        later_export_results << OpenTelemetry::SDK::Trace::Export::FAILURE
        expect(later.join(5)&.value).to be(false)
      ensure
        resume_worker&.close
      end

      it "finishes its captured work before timeout while other jobs keep adding observations" do
        3.times { |index| emit("captured-#{index}") }
        start_flush(timeout: 0.5)

        # Keep the queue nonempty as each captured batch is sent. The final
        # later export is not released until this flush returns.
        emit("later-0")
        release_export << true
        expect(export_started.pop(timeout: 5)).to be(true)
        emit("later-1")
        emit("later-2")
        later_export_results << OpenTelemetry::SDK::Trace::Export::SUCCESS
        expect(export_started.pop(timeout: 5)).to be(true)
        emit("later-3")
        later_export_results << OpenTelemetry::SDK::Trace::Export::SUCCESS
        expect(export_started.pop(timeout: 5)).to be(true)

        expect(flush_results.pop(timeout: 2)).to be(true)
        expect(exported_spans.map(&:name)).to include("later-0")
      end

      it "splits a batch at the earlier flush boundary and reports a later failure only to the later flush" do
        emit("first-job")
        earlier = start_flush
        emit("second-job")
        later = start_flush
        release_export << true

        expect(export_started.pop(timeout: 5)).to be(true)
        expect(exported_spans.map(&:name)).to eq(%w[automatic-export first-job])
        later_export_results << OpenTelemetry::SDK::Trace::Export::SUCCESS
        expect(export_started.pop(timeout: 5)).to be(true)
        expect(earlier.join(1)&.value).to be(true)
        expect(flush_results.pop(timeout: 1)).to be(true)
        expect(flush_results.pop(timeout: 0.05)).to be_nil

        later_export_results << OpenTelemetry::SDK::Trace::Export::FAILURE
        expect(later.join(5)&.value).to be(false)
        expect(client.flush).to be(true)
      end

      it "preserves flush boundaries when waiters are enumerated in reverse capture order" do
        waiters = processor.instance_variable_get(:@flush_waiters)
        # Set does not guarantee capture order; exercise another valid enumeration order.
        allow(waiters).to receive(:each).and_wrap_original do |original, &block|
          entries = []
          original.call { |waiter| entries << waiter }
          entries.reverse_each(&block)
        end
        emit("first-job")
        earlier = start_flush
        emit("second-job")
        later = start_flush
        release_export << true

        expect(export_started.pop(timeout: 5)).to be(true)
        expect(exported_spans.map(&:name)).to eq(%w[automatic-export first-job])
        later_export_results << OpenTelemetry::SDK::Trace::Export::SUCCESS
        expect(earlier.join(1)&.value).to be(true)
        expect(export_started.pop(timeout: 5)).to be(true)
        later_export_results << OpenTelemetry::SDK::Trace::Export::FAILURE
        expect(later.join(5)&.value).to be(false)
        expect(waiters).to be_empty
      end

      it "finishes after captured observations are exported or dropped while later exports remain blocked" do
        3.times { |index| emit("captured-#{index}") }
        flushing = start_flush
        emit("later-0")
        emit("later-1") # Overflows the queue and drops captured-0.
        release_export << true

        expect(export_started.pop(timeout: 5)).to be(true)
        expect(exported_spans.map(&:name)).to eq(%w[automatic-export captured-1 captured-2])
        later_export_results << OpenTelemetry::SDK::Trace::Export::SUCCESS
        expect(export_started.pop(timeout: 5)).to be(true)

        expect(flushing.join(1)&.value).to be(false)
      end

      it "lets a later flush finish its captured work after an earlier flush times out" do
        emit("first-job")
        earlier = start_flush(timeout: 0.05)
        emit("second-job")
        later = start_flush
        expect(earlier.join(1)&.value).to be(false)
        release_export << true

        expect(export_started.pop(timeout: 5)).to be(true)
        later_export_results << OpenTelemetry::SDK::Trace::Export::SUCCESS

        expect(later.join(1)&.value).to be(true)
      end

      it "keeps a completed flush's success when later exports fail before its caller resumes" do
        paused = Queue.new
        resume = Queue.new
        pause_flush_on_wakeup(paused, resume)
        start_flush
        emit("later-failure")
        release_export << true
        expect(paused.pop(timeout: 5)).to be(true)
        expect(export_started.pop(timeout: 5)).to be(true)
        emit("after-failure")
        later_export_results << OpenTelemetry::SDK::Trace::Export::FAILURE
        # Starting another batch proves the failed batch's result was processed.
        expect(export_started.pop(timeout: 5)).to be(true)
        resume << true

        expect(flush_results.pop(timeout: 1)).to be(true)
      ensure
        resume&.close
      end
    end
  end
end
