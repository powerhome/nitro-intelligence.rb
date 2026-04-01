require "spec_helper"
require "nitro_intelligence/media/image_generation"

RSpec.describe NitroIntelligence::ImageGeneration do
  let(:target_image_bytes) { "target_bytes" }
  let(:ref_image_bytes) { "ref_bytes" }

  let(:mock_target_image) do
    instance_double(
      NitroIntelligence::Image,
      mime_type: "image/png",
      base64: "target_b64",
      width: 1920,
      height: 1080
    )
  end

  let(:mock_ref_image) do
    instance_double(
      NitroIntelligence::Image,
      mime_type: "image/jpeg",
      base64: "ref_b64"
    )
  end

  let(:mock_model) do
    NitroIntelligence::ImageModel.new(
      name: "vertex_ai/gemini-3.1-flash-image-preview",
      aspect_ratios: ["1:1", "16:9"],
      resolutions: %w[1K 4K]
    )
  end

  let(:mock_catalog) do
    double("ModelCatalog", default_image_model: mock_model)
  end

  before do
    # Stub the model catalog and the lookup method
    allow(NitroIntelligence).to receive(:model_catalog).and_return(mock_catalog)
    allow(mock_catalog).to receive(:lookup_by_name).with(mock_model.name).and_return(mock_model)

    # Stub Image.new to return our instance doubles when given byte strings
    allow(NitroIntelligence::Image).to receive(:new).with(target_image_bytes).and_return(mock_target_image)
    allow(NitroIntelligence::Image).to receive(:new).with(ref_image_bytes).and_return(mock_ref_image)

    # Optional: Mock string `.present?` behavior if ActiveSupport isn't loaded in your test env
    allow_any_instance_of(String).to receive(:present?).and_return(true)
    allow("").to receive(:present?).and_return(false)
  end

  describe "Config" do
    it "initializes with correct defaults" do
      config = described_class::Config.new

      expect(config.aspect_ratio).to eq("1:1")
      expect(config.model).to eq("vertex_ai/gemini-3.1-flash-image-preview")
      expect(config.resolution).to eq("1K")
    end
  end

  describe "#initialize" do
    context "with only a text message" do
      subject(:generator) { described_class.new(message: "A cool cat") }

      it "builds a text-only message payload" do
        expect(generator.messages).to eq([
                                           {
                                             role: "user",
                                             content: [{ type: "text", text: "A cool cat" }],
                                           },
                                         ])
      end

      it "uses default config values" do
        expect(generator.config.aspect_ratio).to eq("1:1")
      end
    end

    context "with a target image" do
      subject(:generator) { described_class.new(target_image: target_image_bytes) }

      it "assigns the target image" do
        expect(generator.target_image).to eq(mock_target_image)
      end

      it "calculates and sets the closest aspect ratio" do
        # 1920/1080 is 1.777..., which closest matches "16:9"
        expect(generator.config.aspect_ratio).to eq("16:9")
      end

      it "includes the target image in the messages payload" do
        expect(generator.messages.first[:content]).to include(
          {
            type: "image_url",
            image_url: { url: "data:image/png;base64,target_b64" },
          }
        )
      end
    end

    context "with reference images" do
      subject(:generator) { described_class.new(reference_images: [ref_image_bytes]) }

      it "assigns the reference images" do
        expect(generator.reference_images).to eq([mock_ref_image])
      end

      it "includes the reference images in the messages payload" do
        expect(generator.messages.first[:content]).to include(
          {
            type: "image_url",
            image_url: { url: "data:image/jpeg;base64,ref_b64" },
          }
        )
      end
    end

    context "when a block is given" do
      it "yields the config to allow overrides" do
        generator = described_class.new do |config|
          config.aspect_ratio = "16:9"
          config.resolution = "4K"
        end

        expect(generator.config.aspect_ratio).to eq("16:9")
        expect(generator.config.resolution).to eq("4K")
      end
    end
  end

  describe "#files" do
    it "returns an array of all present images without nils" do
      generator = described_class.new(
        target_image: target_image_bytes,
        reference_images: [ref_image_bytes]
      )

      # generated_image is initially nil, so it should be compacted out
      expect(generator.files).to contain_exactly(mock_target_image, mock_ref_image)
    end
  end

  describe "#parse_file" do
    let(:generator) { described_class.new }
    let(:base64_result) { "data:image/png;base64,generated_b64_string" }

    let(:mock_generated_image) do
      instance_double(NitroIntelligence::Image)
    end

    let(:chat_completion) do
      double("ChatCompletion", choices: [
               double("Choice", message: double("Message", to_h: {
                                                  images: [
                                                    { image_url: { url: base64_result } },
                                                  ],
                                                })),
             ])
    end

    before do
      allow(NitroIntelligence::Image).to receive(:from_base64)
        .with(base64_result)
        .and_return(mock_generated_image)

      allow(mock_generated_image).to receive(:direction=)
    end

    it "extracts the base64 string, builds the image, and sets direction to output" do
      expect(mock_generated_image).to receive(:direction=).with("output")

      result = generator.parse_file(chat_completion)

      expect(result).to eq(mock_generated_image)
      expect(generator.generated_image).to eq(mock_generated_image)
    end

    it "returns nil if the base64 string cannot be found in the payload" do
      empty_completion = double("ChatCompletion", choices: [])

      expect(generator.parse_file(empty_completion)).to be_nil
      expect(generator.generated_image).to be_nil
    end
  end
end
