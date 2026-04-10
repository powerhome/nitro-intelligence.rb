require "openai"
require "spec_helper"

RSpec.describe NitroIntelligence::Client do
  let(:fake_project_config) do
    {
      "slug" => "test-slug",
      "public_key" => "fake-public-key",
      "secret_key" => "fake-secret-key",
    }
  end
  let(:fake_langfuse_client) do
    instance_double(NitroIntelligence::LangfuseExtension)
  end

  before do
    allow(NitroIntelligence.config).to receive(:inference_api_key).and_return("fake-inference-api-key")
    allow(NitroIntelligence.config).to receive(:inference_base_url).and_return("https://fake-inference-host.com")
    allow(NitroIntelligence.config).to receive(:model_config).and_return({ default_text_model: "test-model", models: [{ name: "test-model" }] })
    allow(NitroIntelligence.config).to receive(:observability_base_url).and_return("https://fake-observability-host.com")
    allow(NitroIntelligence.config).to receive(:observability_projects).and_return([])
    allow(NitroIntelligence).to receive(:langfuse_clients).and_return({ "test-slug" => fake_langfuse_client })
  end

  describe "#client" do
    it "returns an instance of OpenAI::Client" do
      handler = described_class.new
      expect(handler.client).to be_an_instance_of(OpenAI::Client)
    end
  end

  describe "#chat" do
    it "does not call chat_with_tracing if observability is not available" do
      handler = described_class.new

      allow(handler).to receive(:client_chat)

      expect(handler).not_to receive(:chat_with_tracing)

      handler.chat(message: "hello world")
    end

    it "logs warning when observability is available but no Langfuse client" do
      allow(NitroIntelligence).to receive(:langfuse_clients).and_return({})

      project_slug = "test-slug"
      handler = described_class.new(observability_project_slug: project_slug)

      allow(handler).to receive(:project_config).and_return(fake_project_config)
      allow(handler).to receive(:get_project).and_return(fake_project_config)

      expect(NitroIntelligence.logger).to receive(:warn).with(/Sending request regardless./)
      expect(handler).to receive(:client_chat)

      handler.chat(message: "hello world")
    end

    it "calls chat_with_tracing when observability is available" do
      project_slug = "test-slug"
      handler = described_class.new(observability_project_slug: project_slug)

      expect(handler).to receive(:chat_with_tracing)

      handler.chat(message: "hello world")
    end
  end

  describe "#score" do
    it "raises ObservabilityUnavailableError if observability is not available" do
      handler = described_class.new
      expect do
        handler.score(trace_id: "trace-id", name: "test-score", value: 0.9)
      end.to raise_error(NitroIntelligence::ObservabilityUnavailableError)
    end

    it "raises LangfuseClientNotFoundError if no Langfuse client" do
      allow(NitroIntelligence).to receive(:langfuse_clients).and_return({})

      project_slug = "test-slug"
      handler = described_class.new(observability_project_slug: project_slug)
      expect do
        handler.score(trace_id: "trace-id", name: "test-score", value: 0.9)
      end.to raise_error(NitroIntelligence::LangfuseClientNotFoundError)
    end

    it "calls create_score when observability is available" do
      project_slug = "test-slug"
      handler = described_class.new(observability_project_slug: project_slug)

      expect(fake_langfuse_client).to receive(:create_score).with(id: "trace-id-test-score", trace_id: "trace-id", name: "test-score", value: 0.9, environment: "test")

      handler.score(trace_id: "trace-id", name: "test-score", value: 0.9)
    end

    it "allows overriding the score id" do
      project_slug = "test-slug"
      handler = described_class.new(observability_project_slug: project_slug)

      expect(fake_langfuse_client).to receive(:create_score).with(id: "custom-score-id", trace_id: "trace-id", name: "test-score", value: 0.9, environment: "test")

      handler.score(id: "custom-score-id", trace_id: "trace-id", name: "test-score", value: 0.9)
    end
  end

  describe "#create_dataset_item" do
    it "sends a POST request to create a dataset item" do
      project_slug = "test-slug"
      allow(NitroIntelligence.config).to receive(:observability_projects).and_return([fake_project_config])
      handler = described_class.new(observability_project_slug: project_slug)

      dataset_item_attributes = {
        datasetName: "test-dataset",
        input: "Test input",
        expectedOutput: "Test output",
        metadata: { key: "value" },
      }

      allow(HTTParty).to receive(:post).with("https://fake-observability-host.com/api/public/dataset-items",
                                             body: dataset_item_attributes.to_json,
                                             headers: {
                                               "Content-Type" => "application/json",
                                               "Authorization" => "Basic #{Base64.strict_encode64('fake-public-key:fake-secret-key')}",
                                             }).and_return(double(code: 200))

      response = handler.create_dataset_item(dataset_item_attributes)

      expect(response.code).to eq(200)
    end
  end

  it "defers missing methods to OpenAI::Client" do
    fake_client = instance_double(OpenAI::Client, responses: nil)
    allow(OpenAI::Client).to receive(:new).and_return(fake_client)

    handler = described_class.new

    expect(fake_client).to receive(:responses)
    handler.responses
  end
end
