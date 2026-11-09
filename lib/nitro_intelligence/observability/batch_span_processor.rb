module NitroIntelligence
  module Observability
    # Coordinates flush with the existing export worker instead of exporting a separate
    # queue snapshot. OpenTelemetry Ruby 1.13.1's force_flush misses in-flight batches
    # and waits for export locks without a deadline. Keep its queue, exporter and metrics;
    # wake its worker to drain the queue and wait for completion with a deadline.
    # The OTLP exporter sends synchronously and its force_flush is a no-op, so finishing
    # the worker's export also finishes that batch's delivery attempt.
    #
    # @api private
    class BatchSpanProcessor < OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor
      # Shutdown needs the upstream synchronous drain after stopping the worker.
      # Public flush calls must never take that path, which ignores in-flight batches.
      alias flush_at_shutdown force_flush
      private :flush_at_shutdown

      def force_flush(timeout: nil)
        start_time = OpenTelemetry::Common::Utilities.timeout_timestamp
        remaining = OpenTelemetry::Common::Utilities.maybe_timeout(timeout, start_time)
        return OpenTelemetry::SDK::Trace::Export::TIMEOUT if remaining&.zero?

        lock do
          return OpenTelemetry::SDK::Trace::Export::FAILURE unless @keep_running

          reset_on_fork
          @thread = Thread.new { work } unless @thread&.alive?
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

      def wait_for_exports(timeout, start_time)
        waiter = Object.new
        @flush_waiters[waiter] = OpenTelemetry::SDK::Trace::Export::SUCCESS
        @condition.signal

        loop do
          return OpenTelemetry::SDK::Trace::Export::FAILURE unless @keep_running

          remaining = OpenTelemetry::Common::Utilities.maybe_timeout(timeout, start_time)
          return OpenTelemetry::SDK::Trace::Export::TIMEOUT if remaining&.zero?
          return @flush_waiters.fetch(waiter) if spans.empty? && !@exporting

          @flush_condition.wait(@mutex, remaining)
        end
      ensure
        @flush_waiters.delete(waiter)
      end

      def fail_waiters
        @flush_waiters.transform_values! { OpenTelemetry::SDK::Trace::Export::FAILURE }
      end

      # Unlike the upstream worker, a waiting flush bypasses the scheduled delay for
      # every remaining batch. @exporting covers dequeue through result reporting.
      def work
        loop do
          batch = lock do
            @condition.wait(@mutex, @delay_seconds) if spans.size < batch_size && @keep_running && @flush_waiters.empty?
            @condition.wait(@mutex, @delay_seconds) while spans.empty? && @keep_running
            return unless @keep_running

            @exporting = true
            spans.shift(batch_size)
          end

          export_and_notify(batch)
        end
      end

      def export_and_notify(batch)
        result = OpenTelemetry::SDK::Trace::Export::FAILURE
        @metrics_reporter.observe_value("otel.bsp.buffer_utilization", value: spans.size / max_queue_size.to_f)
        result = export_batch(batch)
      ensure
        lock do
          fail_waiters unless result == OpenTelemetry::SDK::Trace::Export::SUCCESS
          @exporting = false
          @flush_condition.broadcast
        end
      end

      # Queue overflow is reported inside the queue lock. Export failures are
      # reported outside it, and are delivered to waiters by export_and_notify.
      def report_dropped_spans(dropped_spans, reason:, **kwargs)
        fail_waiters if reason == "buffer-full" && dropped_spans.any?
        super
      end

      def reset_on_fork(restart_thread: true)
        return if @pid == Process.pid

        @flush_condition = ConditionVariable.new
        @flush_waiters = {}
        @exporting = false
        super
      end
    end
  end
end
