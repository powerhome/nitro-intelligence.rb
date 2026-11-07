require "spec_helper"
require "webmock/rspec"

require "nitro_intelligence/client/base"
require "nitro_intelligence/client/handlers/embedding_handler"

RSpec.describe NitroIntelligence::Client::Handlers::EmbeddingHandler do
  subject(:handler) { described_class.new(client:) }

  let(:client) { OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example", max_retries: 0) }

  let(:model_config) do
    {
      default_embedding_model: "Qwen/Qwen3-Embedding-0.6B",
      models: [
        { name: "Qwen/Qwen3-Embedding-0.6B", type: "embedding" },
        { name: "other/embedder", type: "embedding" },
        { name: "Qwen/Qwen3-Reranker-0.6B", type: "rerank" },
      ],
    }
  end

  let(:response_headers) do
    { "Content-Type" => "application/json", "x-litellm-response-cost" => "1.0e-07", "x-litellm-call-id" => "call-1" }
  end

  # Answers each request with one vector per input, [batch number, position in batch], listed in
  # reverse to show the vectors are put back in index order.
  let(:requests) { [] }
  let!(:embeddings_route) do
    stub_request(:post, "https://gateway.example/embeddings").to_return do |request|
      body = JSON.parse(request.body)
      requests << body
      data = body["input"].each_with_index.map do |_, index|
        { object: "embedding", index:, embedding: [requests.size.to_f, index.to_f] }
      end
      {
        status: 200,
        headers: response_headers,
        body: {
          object: "list", model: "Qwen/Qwen3-Embedding-0.6B", data: data.reverse,
          usage: { prompt_tokens: body["input"].size * 3, total_tokens: body["input"].size * 3 }
        }.to_json,
      }
    end
  end

  before do
    allow(NitroIntelligence).to receive(:model_catalog).and_return(NitroIntelligence::ModelCatalog.new(model_config))
  end

  describe "#create" do
    it "embeds a single string as a list of one, asking for floats" do
      embeddings = handler.create(input: "How do I request time off?")

      expect(requests).to eq(
        [{ "input" => ["How do I request time off?"], "model" => "Qwen/Qwen3-Embedding-0.6B", "encoding_format" => "float" }]
      )
      expect(embeddings).to be_a(NitroIntelligence::Embeddings)
      expect(embeddings.vector).to eq([1.0, 0.0])
      expect(embeddings.vectors).to eq([[1.0, 0.0]])
      expect(embeddings.model).to eq("Qwen/Qwen3-Embedding-0.6B")
    end

    it "returns the vectors in input order" do
      embeddings = handler.create(input: %w[a b c])

      expect(embeddings.vectors).to eq([[1.0, 0.0], [1.0, 1.0], [1.0, 2.0]])
    end

    it "sends dimensions and user, and keeps the gem's own parameters out of the body" do
      handler.create(
        input: "a",
        parameters: { dimensions: 256, user: "u-1", metadata: { a: 1 }, instruction: "Find", batch_size: 5, trace_name: "t" }
      )

      expect(requests.first.keys).to contain_exactly("input", "model", "encoding_format", "dimensions", "user")
      expect(requests.first).to include("dimensions" => 256, "user" => "u-1")
    end

    it "always asks for floats, whatever encoding the caller asks for" do
      handler.create(input: "a", parameters: { encoding_format: "base64" })

      expect(requests.first["encoding_format"]).to eq("float")
    end

    it "prefixes each input with the instruction in Qwen3-Embedding's query format" do
      handler.create(input: ["How do I request time off?"], parameters: { instruction: "Find the Nitro page that answers this" })

      expect(requests.first["input"]).to eq(["Instruct: Find the Nitro page that answers this\nQuery:How do I request time off?"])
    end

    it "sends the input unchanged when the instruction is blank" do
      handler.create(input: "a", parameters: { instruction: "" })

      expect(requests.first["input"]).to eq(["a"])
    end

    it "sends a long list in batches and returns every vector in order, with usage summed" do
      embeddings = handler.create(input: %w[a b c d e], parameters: { batch_size: 2 })

      expect(requests.map { |request| request["input"] }).to eq([%w[a b], %w[c d], %w[e]])
      expect(embeddings.vectors).to eq([[1.0, 0.0], [1.0, 1.0], [2.0, 0.0], [2.0, 1.0], [3.0, 0.0]])
      expect(embeddings.usage).to eq("prompt_tokens" => 15, "total_tokens" => 15)
      expect(embeddings.responses.size).to eq(3)
    end

    it "batches by 128 by default" do
      handler.create(input: Array.new(129) { |index| "page #{index}" })

      expect(requests.map { |request| request["input"].size }).to eq([128, 1])
    end

    it "sends the gateway headers on every batch" do
      handler.create(input: %w[a b], parameters: { batch_size: 1, metadata: { feature: "page-finder" } })

      expect(
        embeddings_route.with(headers: {
                                "nip-requested-model" => "Qwen/Qwen3-Embedding-0.6B",
                                "x-litellm-spend-logs-metadata" => { feature: "page-finder" }.to_json,
                              })
      ).to have_been_requested.twice
    end

    it "leaves usage out when a response does not report it" do
      stub_request(:post, "https://gateway.example/embeddings").to_return(
        status: 200, headers: response_headers,
        body: { object: "list", model: "m", data: [{ object: "embedding", index: 0, embedding: [0.5] }] }.to_json
      )

      expect(handler.create(input: "a").usage).to eq({})
    end

    it "raises for an empty input before sending anything" do
      expect { handler.create(input: []) }.to raise_error(ArgumentError, /non-empty array of non-empty strings/)
      expect(embeddings_route).not_to have_been_requested
    end

    it "raises for input that is not text" do
      expect { handler.create(input: ["a", 1]) }.to raise_error(ArgumentError, /non-empty array of non-empty strings/)
      expect { handler.create(input: nil) }.to raise_error(ArgumentError, /non-empty array of non-empty strings/)
    end

    it "raises for an empty or blank text anywhere in the input before sending any batch" do
      expect { handler.create(input: "") }.to raise_error(ArgumentError, /non-empty strings/)
      expect { handler.create(input: ["a", "b", " "], parameters: { batch_size: 1 }) }
        .to raise_error(ArgumentError, /non-empty strings/)
      expect(embeddings_route).not_to have_been_requested
    end

    it "raises for a batch size that is not a positive integer" do
      expect { handler.create(input: "a", parameters: { batch_size: 0 }) }
        .to raise_error(ArgumentError, "batch_size must be a positive integer, not 0")
      expect(embeddings_route).not_to have_been_requested
    end

    it "uses the explicitly provided model" do
      handler.create(input: "a", parameters: { model: "other/embedder" })

      expect(requests.first["model"]).to eq("other/embedder")
    end

    it "raises when the requested model is not an embedding model" do
      expect { handler.create(input: "a", parameters: { model: "Qwen/Qwen3-Reranker-0.6B" }) }
        .to raise_error(ArgumentError, "Model 'Qwen/Qwen3-Reranker-0.6B' is not an embedding model")
      expect(embeddings_route).not_to have_been_requested
    end

    it "raises when no model is provided and the catalog has no default" do
      allow(NitroIntelligence).to receive(:model_catalog)
        .and_return(NitroIntelligence::ModelCatalog.new(model_config.except(:default_embedding_model)))

      expect { handler.create(input: "a") }.to raise_error(ArgumentError, /Unsupported model: ''/)
    end

    it "raises the client's errors for a rejected request" do
      stub_request(:post, "https://gateway.example/embeddings").to_return(
        status: 403, body: { error: { message: "no access" } }.to_json, headers: { "Content-Type" => "application/json" }
      )

      expect { handler.create(input: "a") }.to raise_error(OpenAI::Errors::PermissionDeniedError)
    end

    it "leaves a parameters hash given to the client twice unchanged" do
      parameters = { metadata: { ticket: "1" } }
      client = NitroIntelligence::Client::Base.new(client: self.client)

      client.embed(input: "a", parameters:)
      client.embed(input: "b", parameters:)

      expect(parameters).to eq(metadata: { ticket: "1" })
    end
  end

  describe "#cost_details" do
    def embeddings_with_costs(*costs)
      responses = costs.map do |headers|
        usage = OpenAI::Models::CreateEmbeddingResponse::Usage.new(prompt_tokens: 1, total_tokens: 1)
        response = OpenAI::Models::CreateEmbeddingResponse.new(data: [], model: "m", usage:)
        allow(response).to receive(:last_response).and_return(double("ResponseMetadata", headers:))
        response
      end
      NitroIntelligence::Embeddings.new(responses)
    end

    it "adds up the cost of every batch" do
      embeddings = embeddings_with_costs(
        { "x-litellm-response-cost" => "1.0e-07", "x-litellm-response-cost-input" => "1.0e-07" },
        { "x-litellm-response-cost" => "2.0e-07", "x-litellm-response-cost-input" => "2.0e-07" }
      )

      expect(handler.cost_details(embeddings)).to match(total: be_within(1e-12).of(3.0e-07), input: be_within(1e-12).of(3.0e-07))
    end

    it "leaves out a component some batch did not report" do
      embeddings = embeddings_with_costs(
        { "x-litellm-response-cost" => "1.0e-07", "x-litellm-response-cost-input" => "1.0e-07" },
        { "x-litellm-response-cost" => "2.0e-07" }
      )

      expect(handler.cost_details(embeddings).keys).to eq([:total])
    end

    it "leaves the cost unset when any batch was not priced" do
      embeddings = embeddings_with_costs({ "x-litellm-response-cost" => "1.0e-07" }, {})

      expect(handler.cost_details(embeddings)).to be_nil
    end

    it "reads the gateway's cost headers off a real response" do
      expect(handler.cost_details(handler.create(input: %w[a b], parameters: { batch_size: 1 })))
        .to match(total: be_within(1e-12).of(2.0e-07))
    end
  end
end
