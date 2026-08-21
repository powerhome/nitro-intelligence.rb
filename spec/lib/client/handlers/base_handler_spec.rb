require "spec_helper"
require "nitro_intelligence/client/handlers/base_handler"

RSpec.describe NitroIntelligence::Client::Handlers::BaseHandler do
  subject(:handler) { described_class.new(client: double("client")) }

  describe "#add_request_headers" do
    it "creates request_options.extra_headers when none exist" do
      parameters = {}

      handler.send(:add_request_headers, parameters, "nip-modality" => "image")

      expect(parameters).to eq(request_options: { extra_headers: { "nip-modality" => "image" } })
    end

    it "merges headers without clobbering existing request_options (e.g. extra_body)" do
      parameters = {
        request_options: {
          extra_body: { image_config: { image_size: "4K" } },
          extra_headers: { "existing" => "1" },
        },
      }

      handler.send(:add_request_headers, parameters, "nip-modality" => "image")

      expect(parameters[:request_options][:extra_body]).to eq(image_config: { image_size: "4K" })
      expect(parameters[:request_options][:extra_headers]).to eq("existing" => "1", "nip-modality" => "image")
    end

    it "drops headers with nil values (HTTP clients reject a nil header value)" do
      parameters = {}

      handler.send(:add_request_headers, parameters, "nip-modality" => "image", "nip-requested-model" => nil)

      expect(parameters[:request_options][:extra_headers]).to eq("nip-modality" => "image")
    end

    it "returns the parameters hash" do
      parameters = {}

      expect(handler.send(:add_request_headers, parameters, "a" => "b")).to be(parameters)
    end
  end

  describe "#add_correlation_headers" do
    let(:trace_id) { "abcdef0123456789abcdef0123456789" }

    it "sends the supplied trace ID to the inference gateway" do
      parameters = {}

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters.dig(:request_options, :extra_headers, "x-litellm-trace-id")).to eq(trace_id)
    end

    it "sends metadata to the gateway spend logs" do
      parameters = { metadata: { source: "MyJob", rails_request_id: "req-1" } }

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters.dig(:request_options, :extra_headers, "x-litellm-spend-logs-metadata"))
        .to eq('{"source":"MyJob","rails_request_id":"req-1"}')
    end

    it "omits the metadata header when there is no metadata" do
      parameters = { metadata: {} }

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters[:request_options][:extra_headers]).not_to have_key("x-litellm-spend-logs-metadata")
    end

    it "omits metadata that would exceed the header size limit" do
      allow(NitroIntelligence).to receive(:logger).and_return(double("Logger", warn: nil))
      parameters = { metadata: { blob: "x" * 5000 } }

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters[:request_options][:extra_headers]).not_to have_key("x-litellm-spend-logs-metadata")
      expect(parameters.dig(:request_options, :extra_headers, "x-litellm-trace-id")).to eq(trace_id)
    end

    it "preserves headers added by the caller" do
      parameters = {}
      handler.send(:add_request_headers, parameters, "nip-modality" => "image")

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters.dig(:request_options, :extra_headers, "nip-modality")).to eq("image")
    end

    context "when no trace ID is supplied (the unobserved client)" do
      it "adds no correlation headers" do
        parameters = {}

        expect(handler.send(:add_correlation_headers, parameters, trace_id: nil)).to be(parameters)
        expect(parameters).to eq({})
      end

      it "adds nothing even inside an unrelated instrumented span" do
        parameters = {}

        in_span("abcdef0123456789abcdef0123456789") do
          handler.send(:add_correlation_headers, parameters, trace_id: nil)
        end

        expect(parameters).to eq({})
      end
    end

    describe "W3C trace context propagation" do
      it "propagates context when the active span is the one being correlated" do
        parameters = {}

        in_span(trace_id) { handler.send(:add_correlation_headers, parameters, trace_id:) }

        expect(parameters.dig(:request_options, :extra_headers, "traceparent")).to include(trace_id)
      end

      it "propagates nothing when the active span belongs to a different trace" do
        parameters = {}

        in_span("99999999999999999999999999999999") do
          handler.send(:add_correlation_headers, parameters, trace_id:)
        end

        headers = parameters[:request_options][:extra_headers]
        expect(headers).not_to have_key("traceparent")
        expect(headers["x-litellm-trace-id"]).to eq(trace_id)
      end

      it "propagates nothing when there is no active span" do
        parameters = {}

        handler.send(:add_correlation_headers, parameters, trace_id:)

        expect(parameters[:request_options][:extra_headers]).not_to have_key("traceparent")
      end
    end
  end

  # NitroIntelligence::LangfuseTracerProvider installs this propagator at boot.
  def in_span(hex_trace_id, &block)
    OpenTelemetry.propagation = OpenTelemetry::Trace::Propagation::TraceContext::TextMapPropagator.new

    span_context = OpenTelemetry::Trace::SpanContext.new(
      trace_id: [hex_trace_id].pack("H*"),
      span_id: ["0123456789abcdef"].pack("H*")
    )
    span = OpenTelemetry::Trace.non_recording_span(span_context)
    OpenTelemetry::Context.with_current(OpenTelemetry::Trace.context_with_span(span), &block)
  end
end
