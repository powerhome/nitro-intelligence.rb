require "spec_helper"
require "webmock/rspec"

require "nitro_intelligence/client/handlers/embedding_handler"
require "nitro_intelligence/client/handlers/observed/embedding_handler"
require "nitro_intelligence/client/observers/langfuse_observer"
require "nitro_intelligence/observability/project"

RSpec.describe NitroIntelligence::Client::Handlers::Observed::EmbeddingHandler do
  let(:client) { OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example", max_retries: 0) }
  let(:base_handler) { NitroIntelligence::Client::Handlers::EmbeddingHandler.new(client:) }

  let(:fake_prompt_store) { double("PromptStore") }
  let(:fake_project) { double("Project", slug: "test-project", prompt_store: fake_prompt_store, mask_content?: false) }
  let(:fake_project_client) { double("ProjectClient", project: fake_project) }
  let(:fake_observer) { double("LangfuseObserver", project_client: fake_project_client) }
  let(:fake_embedding) { instance_double(Langfuse::Embedding, trace_id: "trace-123", id: "obs-1") }

  let(:handler) { described_class.new(base_handler:, observer: fake_observer) }

  let(:model_config) do
    {
      default_embedding_model: "Qwen/Qwen3-Embedding-0.6B",
      models: [{ name: "Qwen/Qwen3-Embedding-0.6B", type: "embedding", instruction_format: "Instruct: {instruction}\nQuery:{text}" }],
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
    it "observes the request as an embedding with the text as input" do
      expect(fake_observer).to receive(:observe).with(
        "embedding", hash_including(type: :embedding, trace_name: "test-project", input: "How do I request time off?")
      ).and_yield(fake_embedding)

      handler.create(input: "How do I request time off?")
    end

    it "records the input as the model received it, instruction included" do
      expect(fake_observer).to receive(:observe).with(
        "embedding", hash_including(input: ["Instruct: Find the page\nQuery:a"])
      ).and_yield(fake_embedding)

      handler.create(input: ["a"], parameters: { instruction: "Find the page" })
    end

    it "sends the observation's trace ID with every batch" do
      allow(fake_observer).to receive(:observe).and_yield(fake_embedding)

      handler.create(input: %w[a b c], parameters: { batch_size: 2 })

      expect(embeddings_route.with(headers: { "x-litellm-trace-id" => "trace-123" })).to have_been_requested.twice
    end

    it "observes a batched call once" do
      expect(fake_observer).to receive(:observe).once.and_yield(fake_embedding)

      handler.create(input: Array.new(5) { |index| "page #{index}" }, parameters: { batch_size: 2 })
    end

    it "records the model, the vectors' count and size, usage and cost summed over batches, and never the vectors" do
      allow(fake_observer).to receive(:observe).and_yield(fake_embedding)

      embeddings, trace_attributes = handler.create(input: %w[a b c], parameters: { batch_size: 2 })

      expect(embeddings.vectors.size).to eq(3)
      expect(trace_attributes).to match(
        model: "Qwen/Qwen3-Embedding-0.6B",
        output: { count: 3, dimensions: 3 },
        usage_details: { prompt_tokens: 12, total_tokens: 12 },
        cost_details: { total: be_within(1e-12).of(2.0e-07) }
      )
      expect(trace_attributes.to_s).not_to include("0.25")
    end

    it "leaves the cost unset when the gateway did not price the request" do
      response_headers.delete("x-litellm-response-cost")
      allow(fake_observer).to receive(:observe).and_yield(fake_embedding)

      _, trace_attributes = handler.create(input: "a")

      expect(trace_attributes[:cost_details]).to be_nil
    end

    it "uses the supplied trace_name instead of the project slug" do
      expect(fake_observer).to receive(:observe)
        .with("embedding", hash_including(trace_name: "page-finder-index")).and_yield(fake_embedding)

      handler.create(input: "a", parameters: { trace_name: "page-finder-index" })
    end

    it "validates the model and input before observing anything" do
      expect(fake_observer).not_to receive(:observe)

      expect { handler.create(input: "a", parameters: { model: "ghost" }) }.to raise_error(ArgumentError, /Unsupported model/)
      expect { handler.create(input: []) }.to raise_error(ArgumentError, /non-empty/)
    end

    context "with a prompt" do
      let(:prompt) do
        NitroIntelligence::Observability::Prompt.new(
          name: "Page Finder Search", type: "text", version: 4,
          prompt: "Given a question about {{product}}, find the page that answers it",
          config: { candidates: 50, model: "Some/Other-Embedding" }
        )
      end

      before { allow(fake_prompt_store).to receive(:get_prompt).and_return(prompt) }

      it "sends the compiled prompt as the instruction, and observes it under the prompt's name" do
        expect(fake_observer).to receive(:observe).with(
          "embedding",
          hash_including(
            trace_name: "Page Finder Search", prompt:,
            input: "Instruct: Given a question about Nitro, find the page that answers it\nQuery:a"
          )
        ).and_yield(fake_embedding)

        handler.create(input: "a", parameters: { prompt_name: "Page Finder Search", prompt_variables: { product: "Nitro" } })
      end

      it "looks the prompt up at the label or version asked for" do
        allow(fake_observer).to receive(:observe).and_yield(fake_embedding)

        handler.create(input: "a", parameters: { prompt_name: "Page Finder Search", prompt_version: 4 })

        expect(fake_prompt_store).to have_received(:get_prompt)
          .with(prompt_name: "Page Finder Search", prompt_label: nil, prompt_version: 4)
      end

      it "leaves the prompt's config out of the request, so the embedding model stays the one asked for" do
        allow(fake_observer).to receive(:observe).and_yield(fake_embedding)

        handler.create(input: "a", parameters: { prompt_name: "Page Finder Search" })

        expect(embeddings_route.with(body: hash_including(model: "Qwen/Qwen3-Embedding-0.6B"))).to have_been_requested
      end

      it "refuses an instruction as well, before fetching the prompt" do
        expect do
          handler.create(input: "a", parameters: { prompt_name: "Page Finder Search", instruction: "Find the page" })
        end.to raise_error(ArgumentError, /either an instruction or a prompt_name/)

        expect(fake_prompt_store).not_to have_received(:get_prompt)
      end

      it "refuses a chat prompt" do
        chat_prompt = NitroIntelligence::Observability::Prompt.new(
          name: "Assistant", type: "chat", version: 1, prompt: [{ role: "system", content: "Be brief" }]
        )
        allow(fake_prompt_store).to receive(:get_prompt).and_return(chat_prompt)

        expect { handler.create(input: "a", parameters: { prompt_name: "Assistant" }) }
          .to raise_error(ArgumentError, /"Assistant" is a chat prompt/)
        expect(embeddings_route).not_to have_been_requested
      end
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
        allow(observability_client).to receive(:observe).and_yield(embedding)
      end

      it "records the cost through #update" do
        handler.create(input: "a")

        expect(observability_client).to have_received(:observe).with("embedding", hash_including(as_type: :embedding))
        expect(recorded).to include([:update, { cost_details: { total: 1.0e-07 } }])
        expect(recorded).to include([:output=, { count: 1, dimensions: 3 }])
      end

      it "records the prompt's name and version in the observation's metadata" do
        prompt = NitroIntelligence::Observability::Prompt.new(
          name: "Page Finder Search", type: "text", version: 4, prompt: "Find the page"
        )
        allow(project.prompt_store).to receive(:get_prompt).and_return(prompt)

        handler.create(input: "a", parameters: { prompt_name: "Page Finder Search" })

        expect(observability_client).to have_received(:observe).with(
          "embedding", hash_including(metadata: hash_including(prompt_name: "Page Finder Search", prompt_version: "4"))
        )
      end

      context "with a project that masks content" do
        let(:mask_content) { true }

        it "records neither the text nor the output, and asks the gateway to redact its logs" do
          handler.create(input: "How do I request time off?")

          expect(recorded.to_s).not_to include("time off")
          expect(recorded).to include([:input=, "[masked]"], [:output=, "[masked]"])
          expect(embeddings_route.with(headers: { "x-litellm-enable-message-redaction" => "true" })).to have_been_requested
        end
      end
    end
  end
end
