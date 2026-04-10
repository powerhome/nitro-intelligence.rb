require "spec_helper"
require "nitro_intelligence/client/handlers/image_handler"

RSpec.describe NitroIntelligence::Client::Handlers::ImageHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, chat: fake_chat) }
  let(:fake_chat) { double("Chat", completions: fake_completions) }
  let(:fake_completions) { double("Completions") }

  let(:handler) { described_class.new(client: fake_openai_client) }
  let(:fake_image_generation) do
    instance_double(
      NitroIntelligence::ImageGeneration,
      messages: [],
      config: double("Config", model: "custom-model", aspect_ratio: "16:9", resolution: "1024x1024"),
      parse_file: nil
    )
  end

  before do
    allow(NitroIntelligence::ImageGeneration).to receive(:new).and_yield(double.as_null_object).and_return(fake_image_generation)

    fake_catalog = double("ModelCatalog")
    allow(fake_catalog).to receive(:exists?).and_return(true)
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)
  end

  describe "#create" do
    it "generates an image using OpenAI chat completions" do
      expect(fake_completions).to receive(:create).with(
        hash_including(
          model: "custom-model",
          request_options: {
            extra_body: {
              image_config: { aspect_ratio: "16:9", image_size: "1024x1024" },
            },
          }
        )
      ).and_return("fake_chat_completion")

      expect(fake_image_generation).to receive(:parse_file).with("fake_chat_completion")

      response = handler.create(message: "draw a cat", parameters: { model: "custom-model" })
      expect(response).to eq(fake_image_generation)
    end
  end
end
