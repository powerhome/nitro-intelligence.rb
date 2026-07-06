require "spec_helper"
require "nitro_intelligence/client/handlers/text_to_speech_handler"

RSpec.describe NitroIntelligence::Client::Handlers::TextToSpeechHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, audio: fake_audio) }
  let(:fake_audio) { double("Audio", speech: fake_speech) }
  let(:fake_speech) { double("Speech") }

  let(:handler) { described_class.new(client: fake_openai_client) }

  let(:tts_model) do
    NitroIntelligence::TextToSpeechModel.new(
      name: "tts-1",
      default_voice: "alloy",
      default_response_format: "mp3",
      voices: %w[alloy echo nova],
      response_formats: %w[mp3 wav]
    )
  end

  let(:fake_catalog) do
    instance_double(
      NitroIntelligence::ModelCatalog,
      default_text_to_speech_model: tts_model
    )
  end

  before do
    allow(fake_catalog).to receive(:lookup_by_name) do |name|
      name == "tts-1" ? tts_model : nil
    end
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)
  end

  describe "#create" do
    it "sends a speech request to the OpenAI client using model defaults" do
      expect(fake_speech).to receive(:create).with(
        input: "hello world",
        model: "tts-1",
        voice: "alloy",
        response_format: "mp3",
        request_options: { extra_headers: { "nip-modality" => "audio", "nip-requested-model" => "tts-1" } }
      ).and_return("fake_audio_stream")

      response = handler.create(message: "hello world")
      expect(response).to eq("fake_audio_stream")
    end

    it "uses the explicitly provided model" do
      expect(fake_speech).to receive(:create).with(
        hash_including(model: "tts-1", voice: "echo")
      )

      handler.create(message: "hi", parameters: { model: "tts-1", voice: "echo" })
    end

    it "passes through allowed extra parameters (speed, instructions)" do
      expect(fake_speech).to receive(:create).with(
        hash_including(speed: 1.25, instructions: "say it slowly")
      )

      handler.create(
        message: "hi",
        parameters: { speed: 1.25, instructions: "say it slowly" }
      )
    end

    it "filters out parameters not accepted by SpeechCreateParams" do
      expect(fake_speech).to receive(:create) do |kwargs|
        expect(kwargs).not_to have_key(:metadata)
        expect(kwargs).not_to have_key(:trace_name)
      end

      handler.create(
        message: "hi",
        parameters: { trace_name: "t", metadata: { foo: "bar" } }
      )
    end

    it "raises when the requested model is not in the catalog" do
      expect do
        handler.create(message: "hi", parameters: { model: "ghost-tts" })
      end.to raise_error(ArgumentError, /Unsupported model: 'ghost-tts'/)
    end

    it "raises when no model is provided and the catalog has no default" do
      allow(fake_catalog).to receive(:default_text_to_speech_model).and_return(nil)

      expect { handler.create(message: "hi") }
        .to raise_error(ArgumentError, /Unsupported model: ''/)
    end

    it "raises when the requested voice is not supported by the model" do
      expect do
        handler.create(message: "hi", parameters: { voice: "robot" })
      end.to raise_error(ArgumentError, /Unsupported voice: 'robot'/)
    end

    it "raises when the requested response_format is not supported by the model" do
      expect do
        handler.create(message: "hi", parameters: { response_format: "flac" })
      end.to raise_error(ArgumentError, /Unsupported response_format: 'flac'/)
    end
  end
end
