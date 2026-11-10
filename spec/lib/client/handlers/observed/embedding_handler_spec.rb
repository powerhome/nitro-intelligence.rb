require "spec_helper"
require "webmock/rspec"

require "nitro_intelligence/client/handlers/embedding_handler"
require "nitro_intelligence/client/handlers/observed/embedding_handler"
require "nitro_intelligence/client/observers/langfuse_observer"
require "nitro_intelligence/observability/project"

RSpec.describe NitroIntelligence::Client::Handlers::Observed::EmbeddingHandler do
  let(:client) { OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example", max_retries: 0) }
  let(:base_handler) { NitroIntelligence::Client::Handlers::EmbeddingHandler.new(client:) }

  let(:fake_project) { double("Project", slug: "test-project", mask_content?: false) }
  let(:fake_project_client) { double("ProjectClient", project: fake_project) }
  let(:fake_observer) { double("LangfuseObserver", project_client: fake_project_client) }
  let(:fake_embedding) { instance_double(Langfuse::Embedding, trace_id: "trace-123", id: "obs-1") }

  let(:handler) { described_class.new(base_handler:, observer: fake_observer) }

  let(:model_config) do
    {
      default_embedding_model: "Qwen/Qwen3-Embedding-0.6B",
      models: [{ name: "Qwen/Qwen3-Embedding-0.6B", type: "embedding", query_prefix: "Instruct: Find the page\nQuery:" }],
    }
  end

  let(:response_headers) { { "Content-Type" => "application/json", "x-litellm-response-cost" => "1.0e-07" } }

  let!(:embeddings_route) do
    stub_request(:post, "https://gateway.example/embeddings").to_return do |request|
      inputs = JSON.parse(request.body)["input"]
      {
        status: 200,
        headers: response_headers,
        body: {
          object: "list", model: "Qwen/Qwen3-Embedding-0.6B",
          data: inputs.each_with_index.map { |_, index| { object: "embedding", index:, embedding: [0.25, 0.5, 0.75] } },
          usage: { prompt_tokens: inputs.size * 4, total_tokens: inputs.size * 4 }
        }.to_json,
      }
    end
  end

  before do
    allow(NitroIntelligence).to receive(:model_catalog).and_return(NitroIntelligence::ModelCatalog.new(model_config))
  end

  describe "#create" do
    it "observes documents as an embed-documents embedding with the text as input" do
      expect(fake_observer).to receive(:observe).with(
        "embed-documents", hash_including(type: :embedding, trace_name: "test-project", input: ["Time off: request and track PTO"])
      ).and_yield(fake_embedding)

      handler.create(input_type: :document, input: ["Time off: request and track PTO"])
    end

    it "observes a query as an embed-query embedding, recording it as the model received it, prefix included" do
      expect(fake_observer).to receive(:observe).with(
        "embed-query", hash_including(type: :embedding, input: "Instruct: Find the page\nQuery:How do I request time off?")
      ).and_yield(fake_embedding)

      handler.create(input_type: :query, input: "How do I request time off?")
    end

    it "sends the observation's trace ID with every batch" do
      allow(fake_observer).to receive(:observe).and_yield(fake_embedding)

      handler.create(input_type: :document, input: %w[a b c], parameters: { batch_size: 2 })

      expect(embeddings_route.with(headers: { "x-litellm-trace-id" => "trace-123" })).to have_been_requested.twice
    end

    it "observes a batched call once" do
      expect(fake_observer).to receive(:observe).once.and_yield(fake_embedding)

      handler.create(input_type: :document, input: Array.new(5) { |index| "page #{index}" }, parameters: { batch_size: 2 })
    end

    it "records the model, the vectors' count and size, usage and cost summed over batches, and never the vectors" do
      allow(fake_observer).to receive(:observe).and_yield(fake_embedding)

      embeddings, trace_attributes = handler.create(input_type: :document, input: %w[a b c], parameters: { batch_size: 2 })

      expect(embeddings.vectors.size).to eq(3)
      expect(trace_attributes).to match(
        model: "Qwen/Qwen3-Embedding-0.6B",
        output: { count: 3, dimensions: 3 },
        usage_details: { prompt_tokens: 12, total_tokens: 12 },
        cost_details: { total: be_within(1e-12).of(2.0e-07) }
      )
      expect(trace_attributes.to_s).not_to include("0.25")
    end

    context "when a batch fails after others were billed" do
      let(:billed_batch) do
        {
          status: 200,
          headers: response_headers,
          body: {
            object: "list", model: "Qwen/Qwen3-Embedding-0.6B",
            data: [0, 1].map { |index| { object: "embedding", index:, embedding: [0.25] } },
            usage: { prompt_tokens: 8, total_tokens: 8 }
          }.to_json,
        }
      end
      let(:rate_limited) do
        { status: 429, body: { error: { message: "slow down" } }.to_json, headers: { "Content-Type" => "application/json" } }
      end

      before { allow(fake_observer).to receive(:observe).and_yield(fake_embedding) }

      it "records the billed batches' usage and cost, then raises the original error" do
        stub_request(:post, "https://gateway.example/embeddings").to_return(billed_batch).then.to_return(rate_limited)
        allow(fake_embedding).to receive(:update)

        expect { handler.create(input_type: :document, input: %w[a b c], parameters: { batch_size: 2 }) }
          .to raise_error(OpenAI::Errors::RateLimitError)
        expect(fake_embedding).to have_received(:update)
          .with(usage_details: { prompt_tokens: 8, total_tokens: 8 }, cost_details: { total: 1.0e-07 })
      end

      it "records nothing more when the first batch fails" do
        stub_request(:post, "https://gateway.example/embeddings").to_return(rate_limited)
        allow(fake_embedding).to receive(:update)

        expect { handler.create(input_type: :document, input: %w[a b c], parameters: { batch_size: 2 }) }
          .to raise_error(OpenAI::Errors::RateLimitError)
        expect(fake_embedding).not_to have_received(:update)
      end
    end

    it "leaves the cost unset when the gateway did not price the request" do
      response_headers.delete("x-litellm-response-cost")
      allow(fake_observer).to receive(:observe).and_yield(fake_embedding)

      _, trace_attributes = handler.create(input_type: :document, input: "a")

      expect(trace_attributes[:cost_details]).to be_nil
    end

    it "uses the supplied trace_name instead of the project slug" do
      expect(fake_observer).to receive(:observe)
        .with("embed-documents", hash_including(trace_name: "page-finder-index")).and_yield(fake_embedding)

      handler.create(input_type: :document, input: "a", parameters: { trace_name: "page-finder-index" })
    end

    it "validates the model and input before observing anything" do
      expect(fake_observer).not_to receive(:observe)

      expect { handler.create(input_type: :document, input: "a", parameters: { model: "ghost" }) }.to raise_error(ArgumentError, /Unsupported model/)
      expect { handler.create(input_type: :document, input: []) }.to raise_error(ArgumentError, /non-empty/)
      expect { handler.create(input_type: nil, input: "a") }.to raise_error(ArgumentError, /input_type/)
    end

    context "when observed for real" do
      let(:mask_content) { false }
      let(:project) do
        NitroIntelligence::Observability::Project.new(slug: "p", id: "p", public_key: "pk", secret_key: "sk", mask_content:)
      end
      let(:recorded) { [] }
      # langfuse-rb's embedding observation, which has every model setter but cost_details=.
      let(:embedding) do
        double("Embedding", trace_id: "trace-123", id: "obs-1").tap do |embedding|
          allow(embedding).to receive(:update) { |attributes| recorded << [:update, attributes] }
          %i[model= model_parameters= usage_details= input= output=].each do |setter|
            allow(embedding).to receive(setter) { |value| recorded << [setter, value] }
          end
          allow(embedding).to receive(:update_trace) { |attributes| recorded << [:update_trace, attributes] }
        end
      end
      let(:observability_client) { double("ObservabilityClient", observing?: false) }
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
        allow(observability_client).to receive(:observe).and_yield(embedding)
      end

      it "records the cost through #update" do
        handler.create(input_type: :document, input: "a")

        expect(observability_client).to have_received(:observe).with("embed-documents", hash_including(as_type: :embedding))
        expect(recorded).to include([:update, { cost_details: { total: 1.0e-07 } }])
        expect(recorded).to include([:output=, { count: 1, dimensions: 3 }])
      end

      context "with a project that masks content" do
        let(:mask_content) { true }

        it "records neither the text nor the output, and asks the gateway to redact its logs" do
          handler.create(input_type: :query, input: "How do I request time off?")

          expect(recorded.to_s).not_to include("time off")
          expect(recorded).to include([:input=, "[masked]"], [:output=, "[masked]"])
          expect(embeddings_route.with(headers: { "x-litellm-enable-message-redaction" => "true" })).to have_been_requested
        end
      end
    end
  end
end
