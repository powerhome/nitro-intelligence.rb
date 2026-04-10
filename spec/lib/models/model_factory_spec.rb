require "spec_helper"
require "nitro_intelligence/models/model_factory"

RSpec.describe NitroIntelligence::ModelFactory do
  describe ".build" do
    it "symbolizes string keys before building" do
      # Using a mock to intercept the initialized class to ensure keys were symbolized
      expect(NitroIntelligence::TextModel).to receive(:new).with(
        name: "gpt-4",
        max_tokens: 1000
      )

      # ActiveSupport's symbolize_keys should be active in your environment
      described_class.build({ "name" => "gpt-4", "max_tokens" => 1000 })
    end

    context "when the metadata indicates an image model" do
      it "builds and returns an ImageModel if aspect_ratios are present" do
        metadata = { name: "dall-e", aspect_ratios: ["1:1"] }
        model = described_class.build(metadata)

        expect(model).to be_an_instance_of(NitroIntelligence::ImageModel)
      end

      it "builds and returns an ImageModel if resolutions are present" do
        metadata = { name: "dall-e", resolutions: ["1024x1024"] }
        model = described_class.build(metadata)

        expect(model).to be_an_instance_of(NitroIntelligence::ImageModel)
      end
    end

    context "when the metadata indicates a text model" do
      it "builds and returns a TextModel" do
        metadata = { name: "gpt-4" } # No aspect_ratios or resolutions
        model = described_class.build(metadata)

        expect(model).to be_an_instance_of(NitroIntelligence::TextModel)
      end
    end
  end

  describe ".image_model?" do
    it "returns true if :aspect_ratios is a key" do
      expect(described_class.image_model?({ aspect_ratios: [] })).to be true
    end

    it "returns true if :resolutions is a key" do
      expect(described_class.image_model?({ resolutions: [] })).to be true
    end

    it "returns false if neither key is present" do
      expect(described_class.image_model?({ name: "gpt-4", max_tokens: 100 })).to be false
    end
  end
end
