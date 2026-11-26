require "spec_helper"
require "nitro_intelligence/models/model_catalog"

RSpec.describe NitroIntelligence::ModelCatalog do
  let(:model_config) do
    {
      models: [
        { name: "gpt-4", type: "text" },
        { name: "dall-e-3", type: "image", aspect_ratios: ["1:1"] },
        { name: "whisper-1", type: "audio_transcription" },
        { name: "tts-1", type: "text_to_speech" },
        { name: "jev", type: "decision" },
        { name: "qwen-embedding", type: "embedding" },
        { name: "qwen-reranker", type: "rerank" },
      ],
      default_audio_transcription_model: "whisper-1",
      default_image_model: "dall-e-3",
      default_text_model: "gpt-4",
      default_text_to_speech_model: "tts-1",
      default_decision_model: "jev",
      default_embedding_model: "qwen-embedding",
      default_rerank_model: "qwen-reranker",
    }
  end

  let(:fake_gpt4) { double("TextModel", name: "gpt-4") }
  let(:fake_dalle) { double("ImageModel", name: "dall-e-3") }
  let(:fake_whisper) { double("TextModel", name: "whisper-1") }
  let(:fake_tts) { double("TextToSpeechModel", name: "tts-1") }
  let(:fake_jev) { double("DecisionModel", name: "jev") }
  let(:fake_embedding) { double("EmbeddingModel", name: "qwen-embedding") }
  let(:fake_reranker) { double("RerankModel", name: "qwen-reranker") }

  before do
    # Stub the ModelFactory to return our fake models for easy testing
    allow(NitroIntelligence::ModelFactory).to receive(:build)
      .with({ name: "gpt-4", type: "text" })
      .and_return(fake_gpt4)

    allow(NitroIntelligence::ModelFactory).to receive(:build)
      .with({ name: "dall-e-3", type: "image", aspect_ratios: ["1:1"] })
      .and_return(fake_dalle)

    allow(NitroIntelligence::ModelFactory).to receive(:build)
      .with({ name: "whisper-1", type: "audio_transcription" })
      .and_return(fake_whisper)

    allow(NitroIntelligence::ModelFactory).to receive(:build)
      .with({ name: "tts-1", type: "text_to_speech" })
      .and_return(fake_tts)

    allow(NitroIntelligence::ModelFactory).to receive(:build)
      .with({ name: "jev", type: "decision" })
      .and_return(fake_jev)

    allow(NitroIntelligence::ModelFactory).to receive(:build)
      .with({ name: "qwen-embedding", type: "embedding" })
      .and_return(fake_embedding)

    allow(NitroIntelligence::ModelFactory).to receive(:build)
      .with({ name: "qwen-reranker", type: "rerank" })
      .and_return(fake_reranker)
  end

  describe "#initialize" do
    it "builds models using the ModelFactory" do
      catalog = described_class.new(model_config)
      expect(catalog.models).to contain_exactly(
        fake_gpt4, fake_dalle, fake_whisper, fake_tts, fake_jev, fake_embedding, fake_reranker
      )
    end

    it "sets the default models by performing lookups" do
      catalog = described_class.new(model_config)

      expect(catalog.default_text_model).to eq(fake_gpt4)
      expect(catalog.default_image_model).to eq(fake_dalle)
      expect(catalog.default_audio_transcription_model).to eq(fake_whisper)
      expect(catalog.default_text_to_speech_model).to eq(fake_tts)
      expect(catalog.default_decision_model).to eq(fake_jev)
      expect(catalog.default_embedding_model).to eq(fake_embedding)
      expect(catalog.default_rerank_model).to eq(fake_reranker)
    end

    it "accepts string-keyed configuration" do
      string_config = {
        "models" => [{ name: "gpt-4", type: "text" }],
        "default_text_model" => "gpt-4",
      }
      catalog = described_class.new(string_config)

      expect(catalog.default_text_model).to eq(fake_gpt4)
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

  describe "#exists?" do
    let(:catalog) { described_class.new(model_config) }

    it "is true for a model in the catalog and false otherwise" do
      expect(catalog.exists?("dall-e-3")).to be(true)
      expect(catalog.exists?("unknown-model")).to be(false)
    end
  end

  describe "#fetch" do
    let(:catalog) do
      described_class.new(
        models: [
          { name: "gpt-4", type: "text" },
          { name: "tts-1", type: "text_to_speech", default_voice: "alloy", default_response_format: "mp3" },
          { name: "jev", type: "decision" },
        ]
      )
    end

    before { allow(NitroIntelligence::ModelFactory).to receive(:build).and_call_original }

    it "returns the named model when it is of the requested type" do
      expect(catalog.fetch("jev", type: NitroIntelligence::DecisionModel).name).to eq("jev")
    end

    it "accepts a model of any type when no type is requested" do
      expect(catalog.fetch("tts-1")).to be_a(NitroIntelligence::TextToSpeechModel)
    end

    it "raises when no model has the name" do
      expect { catalog.fetch("ghost") }.to raise_error(ArgumentError, "Unsupported model: 'ghost'")
    end

    it "raises, naming the type, when the model is of another type" do
      expect { catalog.fetch("jev", type: NitroIntelligence::TextModel) }
        .to raise_error(ArgumentError, "Model 'jev' is not a text model")
    end

    it "names a kind of model that declares no kind of its own" do
      stub_const("NitroIntelligence::EmbeddingModel", Class.new(NitroIntelligence::Model))

      expect { catalog.fetch("jev", type: NitroIntelligence::EmbeddingModel) }
        .to raise_error(ArgumentError, "Model 'jev' is not an embedding model")
    end
  end

  describe "with the gateway's models" do
    let(:gateway_models) { instance_double(NitroIntelligence::GatewayModels) }
    let(:logger) { instance_double(Logger, warn: nil, debug: nil) }
    let(:catalog) do
      described_class.new(
        {
          default_text_model: "Qwen/Qwen3.6-35B-A3B",
          default_image_model: "google/gemini-3.1-flash-image",
          models: [{ name: "google/gemini-3.1-flash-image", type: "image", aspect_ratios: ["1:1"] }],
        },
        gateway_models
      )
    end
    let(:clock) { [0.0] }

    before do
      allow(NitroIntelligence::ModelFactory).to receive(:build).and_call_original
      allow(NitroIntelligence).to receive(:logger).and_return(logger)
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock.first }
      allow(gateway_models).to receive(:fetch).and_return(
        [
          { "name" => "Qwen/Qwen3.6-35B-A3B", "type" => "text" },
          { "name" => "google/gemini-3.1-flash-image", "type" => "image", "aspect_ratios" => %w[1:1 16:9] },
          { "name" => "google/gemini-3.8-flash-tts", "type" => "text_to_speech" },
        ]
      )
    end

    it "uses a model model_config lists as listed, without asking the gateway" do
      expect(catalog.default_image_model.aspect_ratios).to eq(["1:1"])
      expect(gateway_models).not_to have_received(:fetch)
    end

    it "finds a model model_config does not list among the gateway's" do
      expect(catalog.default_text_model).to be_a(NitroIntelligence::TextModel)
      expect(catalog.fetch("Qwen/Qwen3.6-35B-A3B", type: NitroIntelligence::TextModel).name).to eq("Qwen/Qwen3.6-35B-A3B")
      expect(gateway_models).to have_received(:fetch).once
    end

    it "lists configured models ahead of the gateway's, once each" do
      expect(catalog.models.map(&:name)).to eq(["google/gemini-3.1-flash-image", "Qwen/Qwen3.6-35B-A3B"])
    end

    it "leaves out a gateway model it lacks the settings to build" do
      expect(catalog.lookup_by_name("google/gemini-3.8-flash-tts")).to be_nil
      expect(logger).to have_received(:debug).with(%r{Leaving out gateway model google/gemini-3.8-flash-tts})
    end

    it "leaves out a gateway image model that publishes no aspect ratios or resolutions" do
      allow(gateway_models).to receive(:fetch).and_return(
        [{ "name" => "google/gemini-nano-banana-2.1", "type" => "image", "aspect_ratios" => ["1:1"] }]
      )

      expect(catalog.lookup_by_name("google/gemini-nano-banana-2.1")).to be_nil
      expect(logger).to have_received(:debug).with(/no aspect_ratios or resolutions/)
    end

    it "gives a default's configured name even when no model by that name is available" do
      allow(gateway_models).to receive(:fetch).and_return([])

      expect(catalog.default_text_model).to be_nil
      expect(catalog.default_text_model_name).to eq("Qwen/Qwen3.6-35B-A3B")
    end

    it "asks again for an unknown name only once the last answer is old enough" do
      catalog.lookup_by_name("new/model")
      catalog.lookup_by_name("new/model")
      expect(gateway_models).to have_received(:fetch).once

      clock[0] = described_class::REFRESH_INTERVAL
      catalog.lookup_by_name("new/model")
      expect(gateway_models).to have_received(:fetch).twice
    end

    it "has a thread with no list yet wait for another's request instead of asking again" do
      release = Queue.new
      allow(gateway_models).to receive(:fetch) do
        release.pop
        [{ "name" => "Qwen/Qwen3.6-35B-A3B", "type" => "text" }]
      end

      first = Thread.new { catalog.lookup_by_name("Qwen/Qwen3.6-35B-A3B") }
      Thread.pass until first.status == "sleep"
      second = Thread.new { catalog.lookup_by_name("Qwen/Qwen3.6-35B-A3B") }
      Thread.pass until second.status == "sleep"
      release << :go

      expect([first.value, second.value].map(&:name)).to all(eq("Qwen/Qwen3.6-35B-A3B"))
      expect(gateway_models).to have_received(:fetch).once
    end

    it "keeps answering from the list it has while another thread refreshes it" do
      catalog.lookup_by_name("Qwen/Qwen3.6-35B-A3B")
      release = Queue.new
      allow(gateway_models).to receive(:fetch) do
        release.pop
        []
      end
      clock[0] = described_class::REFRESH_INTERVAL

      refreshing = Thread.new { catalog.lookup_by_name("new/model") }
      Thread.pass until refreshing.status == "sleep"

      expect(catalog.lookup_by_name("Qwen/Qwen3.6-35B-A3B").name).to eq("Qwen/Qwen3.6-35B-A3B")
      release << :go
      refreshing.join
    end

    it "logs a gateway that cannot list its models, and asks again soon after" do
      allow(gateway_models).to receive(:fetch).and_raise(NitroIntelligence::GatewayModels::Error, "503 listing models")

      expect { catalog.fetch("Qwen/Qwen3.6-35B-A3B") }.to raise_error(
        ArgumentError,
        "Unsupported model: 'Qwen/Qwen3.6-35B-A3B' (the last attempt to list the inference gateway's models failed: " \
        "NitroIntelligence::GatewayModels::Error: 503 listing models)"
      )
      expect(logger).to have_received(:warn).with(/503 listing models/)

      clock[0] = described_class::RETRY_INTERVAL
      catalog.lookup_by_name("Qwen/Qwen3.6-35B-A3B")
      expect(gateway_models).to have_received(:fetch).twice
    end
  end
end
