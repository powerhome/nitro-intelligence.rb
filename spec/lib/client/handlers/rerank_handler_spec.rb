require "spec_helper"
require "webmock/rspec"

require "nitro_intelligence/client/base"
require "nitro_intelligence/client/handlers/rerank_handler"

RSpec.describe NitroIntelligence::Client::Handlers::RerankHandler do
  subject(:handler) { described_class.new(client:) }

  let(:client) { OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example", max_retries: 0) }

  let(:model_config) do
    {
      default_rerank_model: "Qwen/Qwen3-Reranker-0.6B",
      models: [
        { name: "Qwen/Qwen3-Reranker-0.6B", type: "rerank" },
        { name: "other/reranker", type: "rerank" },
        { name: "Qwen/Qwen3-Embedding-0.6B", type: "embedding" },
      ],
    }
  end

  let(:query) { "How do I request time off?" }
  let(:documents) { ["Payroll: view your pay stubs", "Time off: request and track PTO", "Directory: find a colleague"] }

  let(:response_body) do
    {
      id: "rerank-1",
      results: [{ index: 1, relevance_score: 0.97 }, { index: 0, relevance_score: 0.12 }, { index: 2, relevance_score: 0.01 }],
      meta: { billed_units: { search_units: 1 }, tokens: { input_tokens: 42 } },
    }
  end

  let(:response_headers) do
    { "Content-Type" => "application/json", "x-litellm-response-cost" => "4.2e-07", "x-litellm-call-id" => "call-9" }
  end

  let!(:rerank_route) do
    stub_request(:post, "https://gateway.example/v1/rerank")
      .to_return(status: 200, body: response_body.to_json, headers: response_headers)
  end

  before do
    allow(NitroIntelligence).to receive(:model_catalog).and_return(NitroIntelligence::ModelCatalog.new(model_config))
  end

  describe "#create" do
    it "posts the model, query and documents to the rerank route" do
      handler.create(query:, documents:)

      expect(rerank_route.with(body: { model: "Qwen/Qwen3-Reranker-0.6B", query:, documents: })).to have_been_requested
    end

    it "sends top_n, and keeps the gem's own parameters out of the body" do
      handler.create(
        query:, documents:,
        parameters: { top_n: 2, instruction: "Find the page", metadata: { a: 1 }, trace_name: "t", trace_documents: false }
      )

      expect(rerank_route.with(body: { model: "Qwen/Qwen3-Reranker-0.6B", query:, documents:, top_n: 2 }))
        .to have_been_requested
    end

    it "returns each document's index and relevance score, most relevant first" do
      response_body[:results].reverse!
      stub_request(:post, "https://gateway.example/v1/rerank").to_return(status: 200, body: response_body.to_json, headers: response_headers)

      ranking = handler.create(query:, documents:)

      expect(ranking).to be_a(NitroIntelligence::Ranking)
      expect(ranking.id).to eq("rerank-1")
      expect(ranking.results).to eq(
        [
          NitroIntelligence::Ranking::Result.new(index: 1, relevance_score: 0.97),
          NitroIntelligence::Ranking::Result.new(index: 0, relevance_score: 0.12),
          NitroIntelligence::Ranking::Result.new(index: 2, relevance_score: 0.01),
        ]
      )
      expect(ranking.meta[:tokens][:input_tokens]).to eq(42)
      expect(ranking.meta["billed_units"]["search_units"]).to eq(1)
    end

    it "keeps the provider's order for documents with tied scores" do
      response_body[:results] = [
        { index: 2, relevance_score: 0.5 }, { index: 0, relevance_score: 0.9 }, { index: 1, relevance_score: 0.5 }
      ]
      stub_request(:post, "https://gateway.example/v1/rerank").to_return(status: 200, body: response_body.to_json, headers: response_headers)

      expect(handler.create(query:, documents:).results.map(&:index)).to eq([0, 2, 1])
    end

    it "returns no results for a response that carries none" do
      stub_request(:post, "https://gateway.example/v1/rerank").to_return(status: 200, body: {}.to_json, headers: response_headers)

      ranking = handler.create(query:, documents:)

      expect(ranking.results).to eq([])
      expect(ranking.meta).to eq({})
    end

    it "sends the requested model and the caller's metadata as gateway headers" do
      handler.create(query:, documents:, parameters: { metadata: { feature: "page-finder" } })

      expect(
        rerank_route.with(headers: {
                            "nip-requested-model" => "Qwen/Qwen3-Reranker-0.6B",
                            "x-litellm-spend-logs-metadata" => { feature: "page-finder" }.to_json,
                          })
      ).to have_been_requested
    end

    it "reaches the gateway's cost headers through the ranking" do
      ranking = handler.create(query:, documents:)

      expect(ranking.last_response.headers["x-litellm-call-id"]).to eq("call-9")
      expect(handler.cost_details(ranking)).to eq(total: 4.2e-07)
    end

    it "posts to /v1/rerank when the base URL already ends in /v1" do
      client = OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example/v1", max_retries: 0)

      described_class.new(client:).create(query:, documents:)

      expect(rerank_route).to have_been_requested.once
    end

    it "posts to /v1/rerank under any other path the base URL has" do
      mounted = stub_request(:post, "https://gateway.example/internal/v1/rerank")
                .to_return(status: 200, body: response_body.to_json, headers: response_headers)
      client = OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example/internal", max_retries: 0)

      described_class.new(client:).create(query:, documents:)

      expect(mounted).to have_been_requested.once
    end

    it "raises the client's errors for a rejected request" do
      stub_request(:post, "https://gateway.example/v1/rerank").to_return(
        status: 403, body: { error: { message: "no access" } }.to_json, headers: { "Content-Type" => "application/json" }
      )

      expect { handler.create(query:, documents:) }.to raise_error(OpenAI::Errors::PermissionDeniedError)
    end

    it "raises for an empty query or empty documents before sending anything" do
      expect { handler.create(query: "", documents:) }.to raise_error(ArgumentError, "query must be a non-empty string")
      expect { handler.create(query:, documents: []) }
        .to raise_error(ArgumentError, "documents must be a non-empty array of strings")
      expect { handler.create(query:, documents: ["a", nil]) }
        .to raise_error(ArgumentError, "documents must be a non-empty array of strings")
      expect(rerank_route).not_to have_been_requested
    end

    it "uses the explicitly provided model" do
      handler.create(query:, documents:, parameters: { model: "other/reranker" })

      expect(rerank_route.with { |request| JSON.parse(request.body)["model"] == "other/reranker" }).to have_been_requested
    end

    it "raises when the requested model is not a rerank model" do
      expect { handler.create(query:, documents:, parameters: { model: "Qwen/Qwen3-Embedding-0.6B" }) }
        .to raise_error(ArgumentError, "Model 'Qwen/Qwen3-Embedding-0.6B' is not a rerank model")
      expect(rerank_route).not_to have_been_requested
    end

    it "raises when no model is provided and the catalog has no default" do
      allow(NitroIntelligence).to receive(:model_catalog)
        .and_return(NitroIntelligence::ModelCatalog.new(model_config.except(:default_rerank_model)))

      expect { handler.create(query:, documents:) }.to raise_error(ArgumentError, /Unsupported model: ''/)
    end

    it "leaves a parameters hash given to the client twice unchanged" do
      parameters = { metadata: { ticket: "1" }, top_n: 1 }
      client = NitroIntelligence::Client::Base.new(client: self.client)

      client.rerank(query:, documents:, parameters:)
      client.rerank(query:, documents:, parameters:)

      expect(parameters).to eq(metadata: { ticket: "1" }, top_n: 1)
    end
  end
end
