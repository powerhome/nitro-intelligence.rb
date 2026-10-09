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

    it "sends the tags naming the feature behind the request" do
      parameters = { gateway_tags: ["cerebro_observability_project_id:proj-1", "cerebro_prompt_name:onboarding"] }

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters.dig(:request_options, :extra_headers, "x-litellm-tags"))
        .to eq("cerebro_observability_project_id:proj-1,cerebro_prompt_name:onboarding")
    end

    it "omits the tags header when there are no tags" do
      parameters = { gateway_tags: [] }

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters[:request_options][:extra_headers]).not_to have_key("x-litellm-tags")
    end

    it "collapses commas in a tag, which the gateway would otherwise read as two tags" do
      parameters = { gateway_tags: ["cerebro_prompt_name:onboarding,welcome"] }

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters.dig(:request_options, :extra_headers, "x-litellm-tags"))
        .to eq("cerebro_prompt_name:onboarding welcome")
    end

    it "collapses newlines in a tag, which an HTTP client would reject outright" do
      parameters = { gateway_tags: ["cerebro_prompt_name:onboarding\r\n  welcome"] }

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters.dig(:request_options, :extra_headers, "x-litellm-tags"))
        .to eq("cerebro_prompt_name:onboarding welcome")
    end

    it "drops a tag that is blank rather than sending an empty one" do
      parameters = { gateway_tags: ["cerebro_observability_project_id:proj-1", "  "] }

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters.dig(:request_options, :extra_headers, "x-litellm-tags"))
        .to eq("cerebro_observability_project_id:proj-1")
    end

    it "preserves headers added by the caller" do
      parameters = {}
      handler.send(:add_request_headers, parameters, "nip-modality" => "image")

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters.dig(:request_options, :extra_headers, "nip-modality")).to eq("image")
    end

    context "when no trace ID is supplied (the unobserved client)" do
      it "sends no trace ID" do
        parameters = { metadata: { source: "MyJob" } }

        handler.send(:add_correlation_headers, parameters, trace_id: nil)

        expect(parameters[:request_options][:extra_headers]).not_to have_key("x-litellm-trace-id")
      end

      it "still attributes gateway spend, which does not depend on anything observing" do
        parameters = { metadata: { source: "MyJob" } }

        handler.send(:add_correlation_headers, parameters, trace_id: nil)

        expect(parameters.dig(:request_options, :extra_headers, "x-litellm-spend-logs-metadata"))
          .to eq('{"source":"MyJob"}')
      end

      it "sends no tags, since nothing knows the project or prompt behind the request" do
        parameters = { metadata: { source: "MyJob" } }

        handler.send(:add_correlation_headers, parameters, trace_id: nil)

        expect(parameters[:request_options][:extra_headers]).not_to have_key("x-litellm-tags")
      end

      it "adds nothing at all when there is no metadata either" do
        parameters = {}

        expect(handler.send(:add_correlation_headers, parameters, trace_id: nil)).to be(parameters)
        expect(parameters[:request_options][:extra_headers]).to eq({})
      end
    end
  end

  describe "#cost_details" do
    def response_with(headers)
      double("Response", last_response: double("LastResponse", headers: headers))
    end

    it "reads the total and the component breakdown the gateway calculated" do
      response = response_with(
        "x-litellm-response-cost" => "5.85e-06",
        "x-litellm-response-cost-input" => "1.1e-06",
        "x-litellm-response-cost-output" => "4.75e-06"
      )

      expect(handler.cost_details(response)).to eq(total: 5.85e-06, input: 1.1e-06, output: 4.75e-06)
    end

    it "returns just the total when the route reports no component breakdown" do
      # Routes whose cost comes from the upstream provider rather than the gateway's
      # own calculation send the total alone.
      response = response_with("x-litellm-response-cost" => "5.6e-06")

      expect(handler.cost_details(response)).to eq(total: 5.6e-06)
    end

    it "returns nil when the gateway did not price the request" do
      # An unpriced deployment omits the header entirely rather than sending a zero,
      # so this must not be reported as a free request.
      expect(handler.cost_details(response_with({}))).to be_nil
    end

    it "returns nil rather than raising when a header is not a number" do
      expect(handler.cost_details(response_with("x-litellm-response-cost" => "free"))).to be_nil
    end

    it "ignores a component header that is not a number but keeps the total" do
      response = response_with(
        "x-litellm-response-cost" => "5.85e-06",
        "x-litellm-response-cost-input" => ""
      )

      expect(handler.cost_details(response)).to eq(total: 5.85e-06)
    end

    it "returns nil for a response carrying no HTTP metadata" do
      # Nested and locally constructed models have no last_response at all.
      expect(handler.cost_details(double("Response"))).to be_nil
      expect(handler.cost_details(double("Response", last_response: nil))).to be_nil
    end
  end
end
