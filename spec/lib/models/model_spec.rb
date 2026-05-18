require "spec_helper"
require "nitro_intelligence/models/model"

RSpec.describe NitroIntelligence::Model do
  describe "#initialize" do
    it "assigns the name" do
      model = described_class.new(name: "gpt-4")
      expect(model.name).to eq("gpt-4")
    end

    it "parses omit_output_fields from strings to arrays of symbols" do
      model = described_class.new(
        name: "gpt-4",
        omit_output_fields: ["choices.0.message", "data.image_base64"]
      )

      expect(model.omit_output_fields).to eq([
                                               %i[choices 0 message],
                                               %i[data image_base64],
                                             ])
    end

    it "defaults omit_output_fields to an empty array" do
      model = described_class.new(name: "gpt-4")
      expect(model.omit_output_fields).to eq([])
    end

    it "ignores extra keyword arguments safely" do
      expect do
        described_class.new(name: "gpt-4", some_unknown_arg: "ignored")
      end.not_to raise_error
    end
  end
end

RSpec.describe NitroIntelligence::TextModel do
  it "inherits from NitroIntelligence::Model" do
    model = described_class.new(name: "claude-3")
    expect(model).to be_a(NitroIntelligence::Model)
    expect(model.name).to eq("claude-3")
  end
end

RSpec.describe NitroIntelligence::ImageModel do
  describe "#initialize" do
    it "assigns aspect_ratios and resolutions" do
      model = described_class.new(
        name: "dall-e-3",
        aspect_ratios: ["16:9", "1:1"],
        resolutions: %w[1024x1024 1024x1792]
      )

      expect(model.name).to eq("dall-e-3")
      expect(model.aspect_ratios).to eq(["16:9", "1:1"])
      expect(model.resolutions).to eq(%w[1024x1024 1024x1792])
    end

    it "defaults arrays to empty if not provided" do
      model = described_class.new(name: "dall-e-3")

      expect(model.aspect_ratios).to eq([])
      expect(model.resolutions).to eq([])
    end
  end
end

RSpec.describe NitroIntelligence::TextToSpeechModel do
  describe "#initialize" do
    it "assigns voice and response_format settings" do
      model = described_class.new(
        name: "tts-1",
        default_voice: "alloy",
        default_response_format: "mp3",
        voices: %w[alloy echo nova],
        response_formats: %w[mp3 wav]
      )

      expect(model.name).to eq("tts-1")
      expect(model.default_voice).to eq("alloy")
      expect(model.default_response_format).to eq("mp3")
      expect(model.voices).to eq(%w[alloy echo nova])
      expect(model.response_formats).to eq(%w[mp3 wav])
    end

    it "defaults voices and response_formats to empty arrays" do
      model = described_class.new(
        name: "tts-1",
        default_voice: "alloy",
        default_response_format: "mp3"
      )

      expect(model.voices).to eq([])
      expect(model.response_formats).to eq([])
    end

    it "inherits from NitroIntelligence::Model" do
      model = described_class.new(
        name: "tts-1",
        default_voice: "alloy",
        default_response_format: "mp3"
      )

      expect(model).to be_a(NitroIntelligence::Model)
    end

    it "ignores unknown keyword arguments (e.g. :type from factory)" do
      expect do
        described_class.new(
          name: "tts-1",
          type: "text_to_speech",
          default_voice: "alloy",
          default_response_format: "mp3"
        )
      end.not_to raise_error
    end
  end
end
