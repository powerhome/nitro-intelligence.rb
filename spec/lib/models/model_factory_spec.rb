require "spec_helper"
require "nitro_intelligence/models/model_factory"

RSpec.describe NitroIntelligence::ModelFactory do
  describe ".build" do
    it "symbolizes string keys before building" do
      expect(NitroIntelligence::TextModel).to receive(:new).with(
        type: "text",
        name: "gpt-4",
        max_tokens: 1000
      )

      described_class.build({ "type" => "text", "name" => "gpt-4", "max_tokens" => 1000 })
    end

    it "builds a TextModel when type is 'text'" do
      model = described_class.build({ type: "text", name: "gpt-4" })
      expect(model).to be_an_instance_of(NitroIntelligence::TextModel)
    end

    it "builds a TextModel when type is 'audio_transcription'" do
      model = described_class.build({ type: "audio_transcription", name: "whisper-1" })
      expect(model).to be_an_instance_of(NitroIntelligence::TextModel)
    end

    it "builds an ImageModel when type is 'image'" do
      model = described_class.build({
                                      type: "image",
                                      name: "dall-e-3",
                                      aspect_ratios: ["1:1"],
                                      resolutions: ["1024x1024"],
                                    })
      expect(model).to be_an_instance_of(NitroIntelligence::ImageModel)
    end

    it "builds a TextToSpeechModel when type is 'text_to_speech'" do
      model = described_class.build({
                                      type: "text_to_speech",
                                      name: "tts-1",
                                      default_voice: "alloy",
                                      default_response_format: "mp3",
                                      voices: ["alloy"],
                                      response_formats: ["mp3"],
                                    })
      expect(model).to be_an_instance_of(NitroIntelligence::TextToSpeechModel)
    end

    it "builds a DecisionModel when type is 'decision'" do
      model = described_class.build({ type: "decision", name: "typesafe/jev-1.14" })
      expect(model).to be_an_instance_of(NitroIntelligence::DecisionModel)
    end

    it "builds an EmbeddingModel when type is 'embedding'" do
      model = described_class.build({ type: "embedding", name: "Qwen/Qwen3-Embedding-0.6B" })
      expect(model).to be_an_instance_of(NitroIntelligence::EmbeddingModel)
      expect(model.instruction_format).to be_nil
    end

    it "builds an EmbeddingModel with its instruction format" do
      model = described_class.build(
        { "type" => "embedding", "name" => "Qwen/Qwen3-Embedding-0.6B", "instruction_format" => "Instruct: {instruction}\nQuery:{text}" }
      )

      expect(model.apply_instruction("Find", "time off")).to eq("Instruct: Find\nQuery:time off")
    end

    it "raises ArgumentError for an instruction format missing a placeholder" do
      expect { described_class.build({ type: "embedding", name: "e", instruction_format: "Instruct: {instruction}" }) }
        .to raise_error(ArgumentError, "instruction_format for 'e' must contain {instruction} and {text}")
    end

    it "builds a RerankModel when type is 'rerank'" do
      model = described_class.build({ type: "rerank", name: "Qwen/Qwen3-Reranker-0.6B" })
      expect(model).to be_an_instance_of(NitroIntelligence::RerankModel)
    end

    it "raises ArgumentError when type is unknown" do
      expect { described_class.build({ type: "audio_synthesis", name: "x" }) }
        .to raise_error(ArgumentError, /Unknown model type: "audio_synthesis"/)
    end

    it "raises ArgumentError when type is missing" do
      expect { described_class.build({ name: "gpt-4" }) }
        .to raise_error(ArgumentError, /Unknown model type: nil/)
    end
  end
end
