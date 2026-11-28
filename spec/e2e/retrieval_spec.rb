require_relative "e2e_helper"

RSpec.describe "NitroIntelligence::Client retrieval", :e2e do
  include_context "with a traced request"

  let(:query) { "How do I book vacation days?" }
  let(:answer) { "To request time off, submit a PTO request in the HR portal for your manager to approve." }
  let(:cafeteria) { "The cafeteria on the second floor serves lunch from noon until two." }

  describe "#embed_query and #embed_documents" do
    it "places a query closer to the document that answers it, and records each call as an embedding" do
      documents = client.embed_documents(documents: [answer, cafeteria], parameters: trace_parameters)
      embedded_query = client.embed_query(query:, parameters: trace_parameters)

      expect(documents.vectors.map(&:size)).to all(eq(embedded_query.vector.size))
      expect(cosine_similarity(embedded_query.vector, documents.vectors[0]))
        .to be > cosine_similarity(embedded_query.vector, documents.vectors[1])

      observations = recorded_trace("embed-documents", "embed-query")
      { "embed-documents" => documents, "embed-query" => embedded_query }.each do |name, embeddings|
        embedding = observation_named(observations, name)
        expect_request(embedding, name:, type: "EMBEDDING")
        expect(embedding["model"]).to eq(embeddings.model)
        expect(CerebroReader.parse(embedding["output"])).to eq(
          "count" => embeddings.vectors.size, "dimensions" => embedded_query.vector.size
        )
        expect_usage(embedding, total: embeddings.usage[:total_tokens])
        expect_cost(embedding, embeddings.responses.sum { gateway_cost(_1) })
      end
      expect(CerebroReader.parse(observation_named(observations, "embed-documents")["input"]))
        .to eq([answer, cafeteria])
      # The query is embedded with the model's query instruction, and Cerebro records what the model saw.
      expect(CerebroReader.parse(observation_named(observations, "embed-query")["input"]))
        .to start_with("Instruct:").and(end_with(query))
    end
  end

  describe "#rerank" do
    let(:documents) { [cafeteria, answer, "Parking passes are issued by building security."] }

    def expect_ranking(ranking, input:)
      generation = recorded_request("rerank")
      expect_request(generation, name: "rerank")
      expect(generation["model"]).to eq(E2eHelpers::RERANK_MODEL)
      expect(CerebroReader.parse(generation["input"])).to eq(input)
      expect(CerebroReader.parse(generation["output"]).max_by { _1["relevance_score"] }).to include("index" => 1)
      # A rerank reports only the tokens it read.
      expect(generation["usageDetails"]).to match("input" => be_positive, "total" => generation.dig("usageDetails", "input"))
      expect_cost(generation, gateway_cost(ranking))
    end

    it "scores the relevant document highest, and records the ranking" do
      ranking = client.rerank(query:, documents:, parameters: trace_parameters)

      expect(ranking.results.max_by(&:relevance_score).index).to eq(1)

      expect_ranking(ranking, input: { "query" => query, "documents" => documents })
    end

    it "records only how many documents there were when asked not to trace them" do
      ranking = client.rerank(query:, documents:, parameters: { trace_documents: false, **trace_parameters })

      expect(ranking.results.max_by(&:relevance_score).index).to eq(1)

      expect_ranking(ranking, input: { "query" => query, "document_count" => 3 })
    end
  end
end
