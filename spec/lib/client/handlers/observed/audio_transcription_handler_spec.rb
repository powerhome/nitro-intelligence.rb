require "spec_helper"
require "nitro_intelligence/client/handlers/observed/audio_transcription_handler"

RSpec.describe NitroIntelligence::Client::Handlers::Observed::AudioTranscriptionHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, audio: fake_audio) }
  let(:fake_audio) { double("Audio", transcriptions: fake_transcriptions) }
  let(:fake_transcriptions) { double("Transcriptions") }

  let(:base_handler) { NitroIntelligence::Client::Handlers::AudioTranscriptionHandler.new(client: fake_openai_client) }

  let(:fake_prompt_store) { double("PromptStore") }
  let(:fake_project) { double("Project", slug: "test-project", prompt_store: fake_prompt_store, auth_token: "auth_token") }
  let(:fake_upload_handler) { double("UploadHandler", upload: nil) }
  let(:fake_project_client) { double("ProjectClient", project: fake_project) }
  let(:fake_observer) { double("LangfuseObserver", project_client: fake_project_client) }

  let(:handler) { described_class.new(base_handler:, observer: fake_observer) }

  before do
    fake_catalog = double("ModelCatalog", default_audio_transcription_model: double(name: "whisper-1"))
    allow(fake_catalog).to receive(:exists?).and_return(true)
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)

    # Mock Audio to have the required methods for upload handler
    allow(NitroIntelligence::Audio).to receive(:new).and_return(
      double("NitroAudio", byte_string: "audio_bytes", mime_type: "audio/mp4", direction: "input", reference_id: nil)
    )

    # Mock UploadHandler to avoid real HTTP calls and use the same instance as expectations
    allow(NitroIntelligence::Observability::UploadHandler).to receive(:new).and_return(fake_upload_handler)
  end

  describe "#create" do
    # FIX: Use a double that responds to `rewind` instead of StringIO
    let(:fake_audio_file) { double("AudioFile", rewind: nil) }
    let(:fake_transcription_response) do
      double("TranscriptionResponse",
             text: "transcribed text",
             usage: double(input_tokens: 10, output_tokens: 20, total_tokens: 30))
    end
    let(:fake_generation) { double("Generation", trace_id: "trace-123") }

    it "observes the request, uploads the file, and builds trace attributes" do
      expect(fake_observer).to receive(:observe).and_yield(fake_generation)

      expect(fake_transcriptions).to receive(:create).with(
        hash_including(prompt: "transcribe", model: "whisper-1", file: fake_audio_file)
      ).and_return(fake_transcription_response)

      expect(fake_upload_handler).to receive(:upload).with("trace-123", upload_queue: instance_of(Queue))

      audio_transcription, trace_attributes = handler.create(message: "transcribe", audio_file: fake_audio_file)

      expect(audio_transcription).to eq(fake_transcription_response)
      expect(trace_attributes[:output]).to eq("transcribed text")
      expect(trace_attributes[:usage_details][:total_tokens]).to eq(30)
    end

    context "with custom metadata" do
      it "passes custom metadata through to the observer" do
        expect(fake_observer).to receive(:observe).with(
          "audio-transcription",
          type: :generation,
          parameters: hash_including(metadata: { custom_key: "custom_value" }),
          trace_name: "test-project",
          prompt: nil
        ).and_yield(fake_generation)

        expect(fake_transcriptions).to receive(:create).with(
          hash_including(prompt: "transcribe", model: "whisper-1", file: fake_audio_file)
        ).and_return(fake_transcription_response)

        expect(fake_upload_handler).to receive(:upload).with("trace-123", upload_queue: instance_of(Queue))

        handler.create(message: "transcribe", audio_file: fake_audio_file, parameters: { metadata: { custom_key: "custom_value" } })
      end
    end

    context "with a prompt" do
      it "prepends the interpolated prompt to the message" do
        fake_prompt = double("Prompt", type: "text", name: "test", compile: "System instruction:", config: {})
        allow(fake_prompt_store).to receive(:get_prompt).and_return(fake_prompt)

        expect(fake_observer).to receive(:observe).and_yield(fake_generation)

        expect(fake_transcriptions).to receive(:create).with(
          hash_including(prompt: "System instruction: transcribe")
        ).and_return(fake_transcription_response)

        expect(fake_upload_handler).to receive(:upload).with("trace-123", upload_queue: instance_of(Queue))

        handler.create(message: "transcribe", audio_file: fake_audio_file, parameters: { prompt_name: "test-prompt" })
      end

      it "raises an error if the prompt is not a text prompt" do
        fake_prompt = double("Prompt", type: "chat", name: "test")
        allow(fake_prompt_store).to receive(:get_prompt).and_return(fake_prompt)

        expect do
          handler.create(message: "transcribe", audio_file: fake_audio_file, parameters: { prompt_name: "test-prompt" })
        end.to raise_error(described_class::ObservedAudioTranscriptionPromptError)
      end
    end
  end
end
