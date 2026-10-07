require "webmock/rspec"

RSpec.shared_context "image edit client" do
  let(:house_bytes) { File.binread(File.expand_path("../fixtures/images/house.png", __dir__)) }
  let(:swatch_bytes) { File.binread(File.expand_path("../fixtures/images/swatch.jpg", __dir__)) }
  let(:real_client) { OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example/v1", max_retries: 0) }
  let(:image_catalog) do
    NitroIntelligence::ModelCatalog.new(
      default_image_model: "default-image",
      models: [
        { name: "default-image", type: "image", aspect_ratios: ["1:1", "4:3", "16:9"], resolutions: %w[1K 2K 4K] },
        { name: "other-image", type: "image" },
      ]
    )
  end

  before do
    allow(NitroIntelligence).to receive(:model_catalog).and_return(image_catalog)
  end
end
