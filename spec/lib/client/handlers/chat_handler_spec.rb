require "spec_helper"
require "nitro_intelligence/client/handlers/chat_handler"

RSpec.describe NitroIntelligence::Client::Handlers::ChatHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, chat: fake_chat) }
  let(:fake_chat) { double("Chat", completions: fake_completions) }
  let(:fake_completions) { double("Completions") }

  let(:handler) { described_class.new(client: fake_openai_client) }

  before do
    fake_model = double("Model", name: "default-text-model")
    fake_catalog = double("ModelCatalog", default_text_model: fake_model)
    allow(fake_catalog).to receive(:exists?).and_return(true)
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)
  end

  describe "#create" do
    it "sends a formatted chat request via the OpenAI client" do
      message = "hello world"

      expect(fake_completions).to receive(:create).with(
        hash_including(
          messages: [{ role: "user", content: "hello world" }],
          model: "default-text-model"
        )
      ).and_return("fake_response")

      response = handler.create(message:)
      expect(response).to eq("fake_response")
    end

    it "allows overriding default parameters" do
      expect(fake_completions).to receive(:create).with(
        hash_including(
          messages: [{ role: "system", content: "Custom" }],
          model: "custom-model"
        )
      )

      handler.create(
        message: "ignored",
        parameters: { model: "custom-model", messages: [{ role: "system", content: "Custom" }] }
      )
    end
  end
end
