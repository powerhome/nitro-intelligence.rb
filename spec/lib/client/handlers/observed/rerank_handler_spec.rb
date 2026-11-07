require "spec_helper"
require "webmock/rspec"

require "nitro_intelligence/client/handlers/rerank_handler"
require "nitro_intelligence/client/handlers/observed/rerank_handler"
require "nitro_intelligence/client/observers/langfuse_observer"
require "nitro_intelligence/observability/project"

RSpec.describe NitroIntelligence::Client::Handlers::Observed::RerankHandler do
  let(:client) { OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example", max_retries: 0) }
  let(:base_handler) { NitroIntelligence::Client::Handlers::RerankHandler.new(client:) }

  let(:fake_project) { double("Project", slug: "test-project", mask_content?: false) }
  let(:fake_project_client) { double("ProjectClient", project: fake_project) }
  let(:fake_observer) { double("LangfuseObserver", project_client: fake_project_client) }
  let(:fake_generation) { instance_double(Langfuse::Generation, trace_id: "trace-123", id: "obs-1") }

  let(:handler) { described_class.new(base_handler:, observer: fake_observer) }

  let(:model_config) do
    { default_rerank_model: "Qwen/Qwen3-Reranker-0.6B", models: [{ name: "Qwen/Qwen3-Reranker-0.6B", type: "rerank" }] }
  end

  let(:query) { "How do I request time off?" }
  let(:documents) { ["Payroll: view your pay stubs", "Time off: request and track PTO"] }
  let(:response_body) do
    {
      id: "rerank-1",
      results: [{ index: 1, relevance_score: 0.97 }, { index: 0, relevance_score: 0.12 }],
      meta: { billed_units: { search_units: 1 }, tokens: { input_tokens: 42 } },
    }
  end
  let(:response_headers) { { "Content-Type" => "application/json", "x-litellm-response-cost" => "4.2e-07" } }

  let!(:rerank_route) do
    stub_request(:post, "https://gateway.example/v1/rerank")
      .to_return(status: 200, body: response_body.to_json, headers: response_headers)
  end

  before do
    allow(NitroIntelligence).to receive(:model_catalog).and_return(NitroIntelligence::ModelCatalog.new(model_config))
  end

  describe "#create" do
    it "observes the request as a generation with the query and documents as input" do
      expect(fake_observer).to receive(:observe).with(
        "rerank", hash_including(type: :generation, trace_name: "test-project", input: { query:, documents: })
      ).and_yield(fake_generation)

      handler.create(query:, documents:)
    end

    it "records the instruction with the query when there is one" do
      expect(fake_observer).to receive(:observe).with(
        "rerank", hash_including(input: { query:, instruction: "Find the page", documents: })
      ).and_yield(fake_generation)

      handler.create(query:, documents:, parameters: { instruction: "Find the page" })
    end

    it "records only how many documents there were when the caller's trace already records them" do
      expect(fake_observer).to receive(:observe).with(
        "rerank", hash_including(input: { query:, document_count: 2 })
      ).and_yield(fake_generation)

      handler.create(query:, documents:, parameters: { trace_documents: false })

      expect(rerank_route.with(body: hash_including(documents:))).to have_been_requested
    end

    it "sends the observation's trace ID to the gateway" do
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)

      handler.create(query:, documents:)

      expect(rerank_route.with(headers: { "x-litellm-trace-id" => "trace-123" })).to have_been_requested
    end

    it "records the indexes and scores, usage and the gateway's cost" do
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)

      ranking, trace_attributes = handler.create(query:, documents:)

      expect(ranking.results.first.index).to eq(1)
      expect(trace_attributes).to eq(
        output: [{ index: 1, relevance_score: 0.97 }, { index: 0, relevance_score: 0.12 }],
        usage_details: { prompt_tokens: 42, total_tokens: 42, search_units: 1 },
        cost_details: { total: 4.2e-07 }
      )
    end

    it "takes the token count from the billed units when the provider reports no tokens" do
      response_body[:meta] = { billed_units: { total_tokens: 30 } }
      stub_request(:post, "https://gateway.example/v1/rerank").to_return(status: 200, body: response_body.to_json, headers: response_headers)
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)

      _, trace_attributes = handler.create(query:, documents:)

      expect(trace_attributes[:usage_details]).to eq(prompt_tokens: 30, total_tokens: 30)
    end

    it "leaves usage and cost unset when the gateway reports neither" do
      stub_request(:post, "https://gateway.example/v1/rerank")
        .to_return(status: 200, body: response_body.except(:meta).to_json, headers: { "Content-Type" => "application/json" })
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)

      _, trace_attributes = handler.create(query:, documents:)

      expect(trace_attributes[:usage_details]).to be_nil
      expect(trace_attributes[:cost_details]).to be_nil
    end

    it "validates the request before observing anything" do
      expect(fake_observer).not_to receive(:observe)

      expect { handler.create(query:, documents: []) }.to raise_error(ArgumentError, /documents/)
    end

    context "with a project that masks content, observed for real" do
      let(:project) do
        NitroIntelligence::Observability::Project.new(slug: "masked", id: "p", public_key: "pk", secret_key: "sk", mask_content: true)
      end
      let(:recorded) { [] }
      let(:generation) do
        double("Generation", trace_id: "trace-123", id: "obs-1").tap do |generation|
          allow(generation).to receive(:update)
          %i[model= model_parameters= usage_details= cost_details= input= output=].each do |setter|
            allow(generation).to receive(setter) { |value| recorded << [setter, value] }
          end
          allow(generation).to receive(:update_trace) { |attributes| recorded << [:update_trace, attributes] }
        end
      end
      let(:observability_client) { double("ObservabilityClient") }
      let(:handler) do
        described_class.new(
          base_handler:,
          observer: NitroIntelligence::Client::Observers::LangfuseObserver.new(
            project_client: double("ProjectClient", project:, observability_client:)
          )
        )
      end

      before do
        allow(Langfuse).to receive(:propagate_attributes).and_yield
        allow(observability_client).to receive(:observe).and_yield(generation)
      end

      it "records neither the query, the documents nor the scores" do
        handler.create(query:, documents:)

        expect(recorded.to_s).not_to include("time off", "Payroll", "0.97")
        expect(recorded).to include([:input=, "[masked]"], [:output=, "[masked]"], [:cost_details=, { total: 4.2e-07 }])
        expect(rerank_route.with(headers: { "x-litellm-enable-message-redaction" => "true" })).to have_been_requested
      end
    end
  end
end
