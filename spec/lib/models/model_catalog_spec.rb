require "spec_helper"
require "nitro_intelligence/models/model_catalog"

RSpec.describe NitroIntelligence::ModelCatalog do
  let(:model_config) do
    {
      models: [
        { name: "gpt-4", type: "text" },
        { name: "dall-e-3", aspect_ratios: ["1:1"] },
        { name: "whisper-1", type: "audio" },
      ],
      default_audio_transcription_model: "whisper-1",
      default_image_model: "dall-e-3",
      default_text_model: "gpt-4",
    }
  end

  let(:fake_gpt4) { double("TextModel", name: "gpt-4") }
  let(:fake_dalle) { double("ImageModel", name: "dall-e-3") }
  let(:fake_whisper) { double("TextModel", name: "whisper-1") }

  before do
    # Stub the ModelFactory to return our fake models for easy testing
    allow(NitroIntelligence::ModelFactory).to receive(:build)
      .with({ name: "gpt-4", type: "text" })
      .and_return(fake_gpt4)

    allow(NitroIntelligence::ModelFactory).to receive(:build)
      .with({ name: "dall-e-3", aspect_ratios: ["1:1"] })
      .and_return(fake_dalle)

    allow(NitroIntelligence::ModelFactory).to receive(:build)
      .with({ name: "whisper-1", type: "audio" })
      .and_return(fake_whisper)
  end

  describe "#initialize" do
    it "builds models using the ModelFactory" do
      catalog = described_class.new(model_config)
      expect(catalog.models).to contain_exactly(fake_gpt4, fake_dalle, fake_whisper)
    end

    it "sets the default models by performing lookups" do
      catalog = described_class.new(model_config)

      expect(catalog.default_text_model).to eq(fake_gpt4)
      expect(catalog.default_image_model).to eq(fake_dalle)
      expect(catalog.default_audio_transcription_model).to eq(fake_whisper)
    end

    it "handles missing :models key gracefully by defaulting to an empty array" do
      empty_config = { default_text_model: "missing-model" }
      catalog = described_class.new(empty_config)

      expect(catalog.models).to eq([])
      expect(catalog.default_text_model).to be_nil
    end
  end

  describe "#lookup_by_name" do
    let(:catalog) { described_class.new(model_config) }

    it "returns the model object when a matching name is found" do
      expect(catalog.lookup_by_name("dall-e-3")).to eq(fake_dalle)
    end

    it "returns nil when no matching name is found" do
      expect(catalog.lookup_by_name("unknown-model")).to be_nil
    end
  end
end
