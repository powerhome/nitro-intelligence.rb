require "spec_helper"
require "nitro_intelligence/client/handlers/observed/completion_handler"

RSpec.describe NitroIntelligence::Client::Handlers::Observed::CompletionHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, completions: fake_completions) }
  let(:fake_completions) { double("Completions") }

  let(:base_handler) { NitroIntelligence::Client::Handlers::CompletionHandler.new(client: fake_openai_client) }

  let(:fake_prompt_store) { double("PromptStore") }
  let(:fake_project) { double("Project", slug: "test-project", prompt_store: fake_prompt_store) }
  let(:fake_project_client) { double("ProjectClient", project: fake_project) }
  let(:fake_observer) { double("LangfuseObserver", project_client: fake_project_client) }
  let(:fake_generation) { double("Generation", trace_id: "abcdef0123456789abcdef0123456789") }

  let(:handler) { described_class.new(base_handler:, observer: fake_observer) }

  let(:fake_completion_response) do
    double("CompletionResponse",
           model: "default-text-model",
           choices: [double(text: "response")],
           usage: double(prompt_tokens: 10, completion_tokens: 20, total_tokens: 30))
  end

  before do
    fake_catalog = double("ModelCatalog", default_text_model: double(name: "default-text-model"))
    allow(fake_catalog).to receive(:exists?).and_return(true)
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)
  end

  describe "#create" do
    it "observes the request and builds trace attributes" do
      expect(fake_observer).to receive(:observe).with(
        "completion",
        type: :generation,
        parameters: instance_of(Hash),
        trace_name: "test-project",
        prompt: nil,
        input: "hello"
      ).and_yield(fake_generation)

      expect(fake_completions).to receive(:create).and_return(fake_completion_response)

      completion, trace_attributes = handler.create(message: "hello")

      expect(completion).to eq(fake_completion_response)
      expect(trace_attributes[:usage_details][:total_tokens]).to eq(30)
      expect(trace_attributes[:output]).to eq("response")
    end

    it "carries the cost the gateway reported into the trace attributes" do
      priced_response = double(
        "CompletionResponse",
        model: "default-text-model",
        choices: [double(text: "response")],
        usage: double(prompt_tokens: 10, completion_tokens: 20, total_tokens: 30),
        last_response: double("LastResponse", headers: {
                                "x-litellm-response-cost" => "5.85e-06",
                                "x-litellm-response-cost-input" => "1.1e-06",
                                "x-litellm-response-cost-output" => "4.75e-06",
                              })
      )

      allow(fake_observer).to receive(:observe).and_yield(fake_generation)
      expect(fake_completions).to receive(:create).and_return(priced_response)

      _, trace_attributes = handler.create(message: "hello")

      expect(trace_attributes[:cost_details]).to eq(total: 5.85e-06, input: 1.1e-06, output: 4.75e-06)
    end

    context "with a text prompt" do
      let(:fake_prompt) do
        NitroIntelligence::Observability::Prompt.new(
          name: "test-prompt",
          type: "text",
          prompt: "You are an assistant. {{foo}}",
          version: 1,
          config: { temperature: 0.8 }
        )
      end

      before { allow(fake_prompt_store).to receive(:get_prompt).and_return(fake_prompt) }

      it "sends the compiled prompt alone when the caller supplies no message" do
        expect(fake_observer).to receive(:observe).with(
          anything,
          hash_including(trace_name: "test-prompt", prompt: fake_prompt, input: "You are an assistant. bar")
        ).and_yield(fake_generation)

        expect(fake_completions).to receive(:create).with(
          hash_including(prompt: "You are an assistant. bar", temperature: 0.8)
        ).and_return(fake_completion_response)

        handler.create(parameters: { prompt_name: "test-prompt", prompt_variables: { foo: "bar" } })
      end

      it "joins the compiled prompt in front of the caller's message" do
        allow(fake_observer).to receive(:observe).and_yield(fake_generation)

        expect(fake_completions).to receive(:create).with(
          hash_including(prompt: "You are an assistant. bar\n\nWhy is the sky blue?")
        ).and_return(fake_completion_response)

        handler.create(
          message: "Why is the sky blue?",
          parameters: { prompt_name: "test-prompt", prompt_variables: { foo: "bar" } }
        )
      end
    end

    context "with a chat prompt" do
      let(:chat_prompt) do
        NitroIntelligence::Observability::Prompt.new(
          name: "chat-prompt",
          type: "chat",
          prompt: [{ role: "system", content: "You are an assistant." }],
          version: 1
        )
      end

      it "refuses it rather than guessing at the model's chat format" do
        allow(fake_prompt_store).to receive(:get_prompt).and_return(chat_prompt)

        expect { handler.create(message: "hi", parameters: { prompt_name: "chat-prompt" }) }
          .to raise_error(described_class::ObservedCompletionPromptError, /must be text: chat-prompt/)
      end
    end

    context "when the prompt config overrides the model (after validate_and_resolve!)" do
      let(:fake_prompt) do
        NitroIntelligence::Observability::Prompt.new(
          name: "test-prompt", type: "text", prompt: "Hi", version: 1, config: { model: "prompt-model" }
        )
      end

      it "stamps nip-requested-model with the final prompt model, not the pre-prompt default" do
        allow(fake_prompt_store).to receive(:get_prompt).and_return(fake_prompt)
        allow(fake_observer).to receive(:observe).and_yield(fake_generation)

        expect(fake_completions).to receive(:create) do |kwargs|
          expect(kwargs[:model]).to eq("prompt-model")
          expect(kwargs.dig(:request_options, :extra_headers, "nip-requested-model")).to eq("prompt-model")
          fake_completion_response
        end

        handler.create(message: "hello", parameters: { prompt_name: "test-prompt" })
      end
    end
  end
end
