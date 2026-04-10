require "spec_helper"
require "nitro_intelligence/client/handlers/audio_transcription_handler"

RSpec.describe NitroIntelligence::Client::Handlers::AudioTranscriptionHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, audio: fake_audio) }
  let(:fake_audio) { double("Audio", transcriptions: fake_transcriptions) }
  let(:fake_transcriptions) { double("Transcriptions") }

  let(:handler) { described_class.new(client: fake_openai_client) }

  before do
    fake_model = double("Model", name: "default-audio-model")
    fake_catalog = double("ModelCatalog", default_audio_transcription_model: fake_model)
    allow(fake_catalog).to receive(:exists?).and_return(true)
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)
  end

  describe "#create" do
    it "sends an audio transcription request via the OpenAI client" do
      audio_file = double("File")

      expect(fake_transcriptions).to receive(:create).with(
        prompt: "transcribe this",
        model: "default-audio-model",
        file: audio_file,
        temperature: 0.5
      ).and_return("fake_transcription")

      response = handler.create(message: "transcribe this", audio_file:, parameters: { temperature: 0.5, trace_name: "test" })
      expect(response).to eq("fake_transcription")
    end
  end
end
