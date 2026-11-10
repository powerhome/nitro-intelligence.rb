module NitroIntelligence
  module Observability
    # Coordinates flush with the existing export worker instead of exporting a separate
    # queue snapshot. OpenTelemetry Ruby 1.13.1's force_flush misses in-flight batches
    # and waits for export locks without a deadline. Keep its queue, exporter and metrics;
    # wake its worker and wait for the work captured at the call's start with a deadline.
    # The OTLP exporter sends synchronously and its force_flush is a no-op, so finishing
    # the worker's export also finishes that batch's delivery attempt.
    #
    # Upstream fix requested in https://github.com/open-telemetry/opentelemetry-ruby/issues/2497;
    # once it ships, this subclass can be replaced by the SDK's own force_flush.
    #
    # @api private
    class BatchSpanProcessor < OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor
      # Each call captures a prefix of the FIFO queue and the current export, if any.
      # Counts shrink on dequeue or overflow; later spans never extend a call's work.
      #
      # @api private
      FlushWaiter = Struct.new(:queued, :exporting, :result) do
        def pending?
          queued.positive? || exporting
        end
      end

      # Shutdown needs the upstream synchronous drain after stopping the worker.
      # Public flush calls must never take that path, which ignores in-flight batches.
      alias flush_at_shutdown force_flush
      private :flush_at_shutdown

      def force_flush(timeout: nil)
        start_time = OpenTelemetry::Common::Utilities.timeout_timestamp

        lock do
          return OpenTelemetry::SDK::Trace::Export::FAILURE unless @keep_running

          remaining = OpenTelemetry::Common::Utilities.maybe_timeout(timeout, start_time)
          if remaining&.zero?
            return OpenTelemetry::SDK::Trace::Export::SUCCESS if spans.empty? && !@exporting

            return OpenTelemetry::SDK::Trace::Export::TIMEOUT
          end

          reset_on_fork(restart_thread: false)
          return OpenTelemetry::SDK::Trace::Export::FAILURE unless start_worker

          wait_for_exports(timeout, start_time)
        end
      end

      # Preserve the SDK's teardown, but wake waiting flush callers and use the
      # private upstream drain instead of dispatching back to public force_flush.
      def shutdown(timeout: nil)
        start_time = OpenTelemetry::Common::Utilities.timeout_timestamp
        thread = lock do
          return OpenTelemetry::SDK::Trace::Export::FAILURE unless @keep_running

          @keep_running = false
          @condition.signal
          @flush_condition.broadcast
          @thread
        end

        thread&.join(timeout)
        flush_at_shutdown(timeout: OpenTelemetry::Common::Utilities.maybe_timeout(timeout, start_time))
        dropped_spans = lock { spans.shift(spans.length) }
        report_dropped_spans(dropped_spans, reason: "terminating") if dropped_spans.any?
        @exporter.shutdown(timeout: OpenTelemetry::Common::Utilities.maybe_timeout(timeout, start_time))
      end

    private

      def start_worker
        return @thread if @thread&.alive?

        @thread = Thread.new { work }
      rescue ThreadError => e
        @metrics_reporter.add_to_counter("otel.bsp.error", labels: { "reason" => "ThreadError" })
        OpenTelemetry.handle_error(exception: e, message: "unexpected error in BatchSpanProcessor#start_worker")
        nil
      end

      def wait_for_exports(timeout, start_time)
        waiter = FlushWaiter.new(spans.size, @exporting, OpenTelemetry::SDK::Trace::Export::SUCCESS)
        @flush_waiters.add(waiter)
        @condition.signal

        loop do
          return waiter.result unless waiter.pending?
          return OpenTelemetry::SDK::Trace::Export::FAILURE unless @keep_running

          remaining = OpenTelemetry::Common::Utilities.maybe_timeout(timeout, start_time)
          return OpenTelemetry::SDK::Trace::Export::TIMEOUT if remaining&.zero?

          @flush_condition.wait(@mutex, remaining)
        end
      ensure
        @flush_waiters.delete(waiter)
      end

      # Find the batch limit while collecting waiters; Set iteration order is unspecified.
      def queued_flushes
        waiters = []
        limit = batch_size
        @flush_waiters.each do |waiter|
          next unless waiter.queued.positive?

          waiters << waiter
          limit = waiter.queued if waiter.queued < limit
        end
        [waiters, limit]
      end

      # Unlike the upstream worker, a waiting flush bypasses the scheduled delay for
      # its remaining batches. @exporting covers dequeue through result reporting.
      def work
        loop do
          batch = lock do
            waiters, limit = queued_flushes
            if spans.size < batch_size && @keep_running && waiters.empty?
              @condition.wait(@mutex, @delay_seconds)
              @condition.wait(@mutex, @delay_seconds) while spans.empty? && @keep_running
              # Waiting releases the lock; callers may register or time out before we resume.
              waiters, limit = queued_flushes
            end
            return unless @keep_running

            take_batch(waiters, limit)
          end

          export_and_notify(batch)
        end
      end

      # Split at the earliest flush boundary so a batch never mixes that call's
      # captured observations with later work. This runs under the queue lock.
      def take_batch(waiters, limit)
        batch = spans.shift(limit)
        waiters.each do |waiter|
          waiter.queued -= batch.size
          waiter.exporting = true
        end
        @exporting = true
        batch
      end

      def export_and_notify(batch)
        result = OpenTelemetry::SDK::Trace::Export::FAILURE
        @metrics_reporter.observe_value("otel.bsp.buffer_utilization", value: spans.size / max_queue_size.to_f)
        result = export_batch(batch)
      ensure
        lock do
          @flush_waiters.each do |waiter|
            next unless waiter.exporting

            unless result == OpenTelemetry::SDK::Trace::Export::SUCCESS
              waiter.result = OpenTelemetry::SDK::Trace::Export::FAILURE
            end
            waiter.exporting = false
          end
          @exporting = false
          @flush_condition.broadcast
        end
      end

      # Queue overflow is reported inside the queue lock. Export failures are
      # reported outside it, and are delivered to waiters by export_and_notify.
      def report_dropped_spans(dropped_spans, reason:, **kwargs)
        if reason == "buffer-full" && dropped_spans.any?
          @flush_waiters.each do |waiter|
            next unless waiter.queued.positive?

            waiter.queued = [waiter.queued - dropped_spans.size, 0].max
            waiter.result = OpenTelemetry::SDK::Trace::Export::FAILURE
          end
          @flush_condition.broadcast
        end
        super
      end

      def reset_on_fork(restart_thread: true)
        return if @pid == Process.pid

        @flush_condition = ConditionVariable.new
        @flush_waiters = Set.new.compare_by_identity
        @exporting = false
        super
      end
    end
  end
end
