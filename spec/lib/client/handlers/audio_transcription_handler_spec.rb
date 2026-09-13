require "spec_helper"
require "webmock/rspec"

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
        temperature: 0.5,
        request_options: { extra_headers: { "nip-modality" => "audio", "nip-requested-model" => "default-audio-model" } }
      ).and_return("fake_transcription")

      response = handler.create(message: "transcribe this", audio_file:, parameters: { temperature: 0.5, trace_name: "test" })
      expect(response).to eq("fake_transcription")
    end
  end

  # See the note in chat_handler_spec: the cost path is covered against a real
  # OpenAI::Client once per kind of response the SDK returns.
  describe "the cost of a real transcription response" do
    subject(:handler) { described_class.new(client: real_client) }

    let(:real_client) { OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example") }

    before do
      stub_request(:post, "https://gateway.example/audio/transcriptions").to_return(
        status: 200,
        body: { text: "transcribed text" }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "x-litellm-response-cost" => "5.85e-06",
          "x-litellm-response-cost-input" => "1.1e-06",
          "x-litellm-response-cost-output" => "4.75e-06",
        }
      )
    end

    it "reaches the gateway's cost headers through the returned transcription" do
      audio_transcription = handler.create(
        audio_file: OpenAI::FilePart.new(StringIO.new("audio_bytes"), filename: "audio.mp3"),
        message: "transcribe this"
      )

      expect(audio_transcription.text).to eq("transcribed text")
      expect(handler.cost_details(audio_transcription)).to eq(total: 5.85e-06, input: 1.1e-06, output: 4.75e-06)
    end
  end
end
