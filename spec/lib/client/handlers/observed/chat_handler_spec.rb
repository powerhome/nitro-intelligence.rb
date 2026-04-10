require "spec_helper"
require "nitro_intelligence/client/handlers/observed/chat_handler"

RSpec.describe NitroIntelligence::Client::Handlers::Observed::ChatHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, chat: fake_chat) }
  let(:fake_chat) { double("Chat", completions: fake_completions) }
  let(:fake_completions) { double("Completions") }

  let(:base_handler) { NitroIntelligence::Client::Handlers::ChatHandler.new(client: fake_openai_client) }

  let(:fake_prompt_store) { double("PromptStore") }
  let(:fake_project) { double("Project", slug: "test-project", prompt_store: fake_prompt_store) }
  let(:fake_project_client) { double("ProjectClient", project: fake_project) }
  let(:fake_observer) { double("LangfuseObserver", project_client: fake_project_client) }

  let(:handler) { described_class.new(base_handler:, observer: fake_observer) }

  before do
    fake_catalog = double("ModelCatalog", default_text_model: double(name: "default-text-model"))
    allow(fake_catalog).to receive(:exists?).and_return(true)
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)
  end

  describe "#create" do
    let(:fake_completion_response) do
      double("CompletionResponse",
             model: "gpt-4",
             choices: [double(message: double(to_h: { "content" => "response" }))],
             usage: double(prompt_tokens: 10, completion_tokens: 20, total_tokens: 30))
    end

    it "observes the request and builds trace attributes" do
      # Yields the fake generation so the block executes
      expect(fake_observer).to receive(:observe).with(
        "chat-completion",
        type: :generation,
        parameters: instance_of(Hash),
        trace_name: "test-project",
        prompt: nil
      ).and_yield(double("Generation"))

      expect(fake_completions).to receive(:create).and_return(fake_completion_response)

      chat_completion, trace_attributes = handler.create(message: "hello")

      expect(chat_completion).to eq(fake_completion_response)
      expect(trace_attributes[:usage_details][:total_tokens]).to eq(30)
      expect(trace_attributes[:output]).to eq({ "content" => "response" })
    end

    context "with custom metadata" do
      it "passes custom metadata through to the observer" do
        expect(fake_observer).to receive(:observe).with(
          "chat-completion",
          type: :generation,
          parameters: hash_including(metadata: { custom_key: "custom_value" }),
          trace_name: "test-project",
          prompt: nil
        ).and_yield(double("Generation"))

        expect(fake_completions).to receive(:create).and_return(fake_completion_response)

        handler.create(message: "hello", parameters: { metadata: { custom_key: "custom_value" } })
      end
    end

    context "with a prompt" do
      let(:fake_prompt) do
        double("Prompt", name: "test-prompt", config: { temperature: 0.8 })
      end

      it "interpolates the prompt and applies config" do
        allow(fake_prompt_store).to receive(:get_prompt).and_return(fake_prompt)
        expect(fake_prompt).to receive(:interpolate).and_return([{ role: "user", content: "interpolated hello" }])

        expect(fake_observer).to receive(:observe).with(
          anything,
          hash_including(trace_name: "test-prompt", prompt: fake_prompt)
        ).and_yield(double)

        expect(fake_completions).to receive(:create).with(
          hash_including(messages: [{ role: "user", content: "interpolated hello" }], temperature: 0.8)
        ).and_return(fake_completion_response)

        handler.create(message: "hello", parameters: { prompt_name: "test-prompt" })
      end
    end
  end
end
