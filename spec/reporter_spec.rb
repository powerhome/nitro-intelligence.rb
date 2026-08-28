require "openai"
require "spec_helper"
require "webmock/rspec"

RSpec.describe NitroIntelligence::Reporter do
  let(:auth_token) { Base64.strict_encode64("fake-public-key:fake-secret-key") }
  let(:fake_project) do
    double("Observability::Project", public_key: "fake-public-key", secret_key: "fake-secret-key", auth_token:)
  end

  let(:fake_langfuse_client) do
    instance_double(NitroIntelligence::LangfuseExtension)
  end

  let(:fake_project_client) do
    double("Observability::ProjectClient", observability_client: fake_langfuse_client, project: fake_project)
  end

  let(:fake_registry) do
    double("Observability::ProjectClientRegistry")
  end

  before do
    allow(NitroIntelligence.config).to receive(:observability_base_url).and_return("https://fake-observability-host.com")
    allow(NitroIntelligence).to receive(:environment).and_return("test")

    allow(NitroIntelligence).to receive(:project_client_registry).and_return(fake_registry)
    allow(fake_registry).to receive(:fetch).with("test-slug").and_return(fake_project_client)
  end

  describe "#initialize" do
    it "raises Observability::ProjectClient::NotFoundError if no project session is found" do
      allow(fake_registry).to receive(:fetch).with("test-slug").and_return(nil)

      expect do
        described_class.new(observability_project_slug: "test-slug")
      end.to raise_error(NitroIntelligence::Observability::ProjectClient::NotFoundError)
    end
  end

  describe "#score" do
    it "calls create_score when observability is available" do
      handler = described_class.new(observability_project_slug: "test-slug")

      expect(fake_langfuse_client).to receive(:create_score).with(
        id: "trace-id-test-score",
        trace_id: "trace-id",
        name: "test-score",
        value: 0.9,
        environment: "test"
      )

      handler.score(trace_id: "trace-id", name: "test-score", value: 0.9)
    end

    it "allows overriding the score id" do
      handler = described_class.new(observability_project_slug: "test-slug")

      expect(fake_langfuse_client).to receive(:create_score).with(
        id: "custom-score-id",
        trace_id: "trace-id",
        name: "test-score",
        value: 0.9,
        environment: "test"
      )

      handler.score(id: "custom-score-id", trace_id: "trace-id", name: "test-score", value: 0.9)
    end
  end

  describe "#create_dataset_item" do
    it "sends a POST request to create a dataset item" do
      handler = described_class.new(observability_project_slug: "test-slug")

      dataset_item_attributes = {
        datasetName: "test-dataset",
        input: "Test input",
        expectedOutput: "Test output",
        metadata: { key: "value" },
      }

      stub = stub_request(:post, "https://fake-observability-host.com/api/public/dataset-items")
             .with(
               body: dataset_item_attributes.to_json,
               headers: {
                 "Content-Type" => "application/json",
                 "Authorization" => "Basic #{auth_token}",
               }
             )
             .to_return(status: 200, body: "", headers: {})

      response = handler.create_dataset_item(dataset_item_attributes)

      expect(stub).to have_been_requested
      expect(response.code).to eq("200")
    end

    it "returns the response for any successful status, not only 200" do
      handler = described_class.new(observability_project_slug: "test-slug")

      stub_request(:post, "https://fake-observability-host.com/api/public/dataset-items")
        .to_return(status: 201, body: "", headers: {})

      expect(handler.create_dataset_item({ datasetName: "test-dataset" }).code).to eq("201")
    end

    it "raises when the item is rejected, rather than returning the failure as if it worked" do
      handler = described_class.new(observability_project_slug: "test-slug")

      stub_request(:post, "https://fake-observability-host.com/api/public/dataset-items")
        .to_return(status: 400, body: "dataset not found", headers: {})

      expect do
        handler.create_dataset_item({ datasetName: "missing-dataset" })
      end.to raise_error(NitroIntelligence::Reporter::DatasetItemError, /400.*dataset not found/)
    end

    it "raises on an unauthorized write" do
      handler = described_class.new(observability_project_slug: "test-slug")

      stub_request(:post, "https://fake-observability-host.com/api/public/dataset-items")
        .to_return(status: 401, body: "", headers: {})

      expect do
        handler.create_dataset_item({ datasetName: "test-dataset" })
      end.to raise_error(NitroIntelligence::Reporter::DatasetItemError, /401/)
    end
  end
end
