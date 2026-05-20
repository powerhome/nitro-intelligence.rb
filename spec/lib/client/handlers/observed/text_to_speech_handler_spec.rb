require "spec_helper"
require "nitro_intelligence/client/handlers/observed/text_to_speech_handler"

RSpec.describe NitroIntelligence::Client::Handlers::Observed::TextToSpeechHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, audio: fake_audio) }
  let(:fake_audio) { double("Audio", speech: fake_speech) }
  let(:fake_speech) { double("Speech") }

  let(:base_handler) { NitroIntelligence::Client::Handlers::TextToSpeechHandler.new(client: fake_openai_client) }

  let(:fake_prompt_store) { double("PromptStore") }
  let(:fake_project) { double("Project", slug: "test-project", prompt_store: fake_prompt_store, auth_token: "auth_token") }
  let(:fake_uploaded_media) { double("UploadedMedia", mime_type: "audio/mp3", reference_id: "media-321") }
  let(:fake_upload_handler) { double("UploadHandler", upload: nil, uploaded_media: [fake_uploaded_media]) }
  let(:fake_project_client) { double("ProjectClient", project: fake_project) }
  let(:fake_observer) { double("LangfuseObserver", project_client: fake_project_client) }

  let(:handler) { described_class.new(base_handler:, observer: fake_observer) }

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
    instance_double(NitroIntelligence::ModelCatalog, default_text_to_speech_model: tts_model)
  end

  let(:fake_tts_response) { StringIO.new("fake_audio_bytes") }
  let(:fake_generation) { double("Generation", trace_id: "trace-321") }

  before do
    allow(fake_catalog).to receive(:lookup_by_name).and_return(tts_model)
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)

    allow(NitroIntelligence::Audio).to receive(:new).and_return(
      double("NitroAudio", byte_string: "audio_bytes", mime_type: "audio/mp3", direction: "output", reference_id: nil)
    )

    allow(NitroIntelligence::Observability::UploadHandler).to receive(:new).and_return(fake_upload_handler)
  end

  describe "#create" do
    it "observes the request, uploads the audio, and builds trace attributes" do
      expect(fake_observer).to receive(:observe).with(
        "text-to-speech",
        hash_including(type: :generation, trace_name: "test-project", prompt: nil)
      ).and_yield(fake_generation)

      expect(fake_speech).to receive(:create).with(
        hash_including(input: "say hi", model: "tts-1", voice: "alloy", response_format: "mp3")
      ).and_return(fake_tts_response)

      expect(fake_upload_handler).to receive(:upload).with("trace-321", upload_queue: instance_of(Queue))

      tts, trace_attributes = handler.create(message: "say hi")

      expect(tts).to eq(fake_tts_response)
      expect(trace_attributes[:model]).to eq("tts-1")
      expect(trace_attributes[:input]).to eq("say hi")
      expect(trace_attributes[:output]).to eq("@@@langfuseMedia:type=audio/mp3|id=media-321|source=bytes@@@")
    end

    context "with a custom trace_name" do
      it "uses the supplied trace_name instead of the project slug" do
        expect(fake_observer).to receive(:observe).with(
          "text-to-speech",
          hash_including(trace_name: "custom-trace")
        ).and_yield(fake_generation)

        expect(fake_speech).to receive(:create).and_return(fake_tts_response)
        expect(fake_upload_handler).to receive(:upload)

        handler.create(message: "say hi", parameters: { trace_name: "custom-trace" })
      end
    end

    context "with custom metadata" do
      it "passes custom metadata through to the observer" do
        expect(fake_observer).to receive(:observe).with(
          "text-to-speech",
          hash_including(parameters: hash_including(metadata: { custom_key: "custom_value" }))
        ).and_yield(fake_generation)

        expect(fake_speech).to receive(:create).and_return(fake_tts_response)
        expect(fake_upload_handler).to receive(:upload)

        handler.create(message: "say hi", parameters: { metadata: { custom_key: "custom_value" } })
      end
    end

    context "with a prompt" do
      let(:fake_prompt) do
        double("Prompt", type: "text", name: "tts-prompt", compile: "speak softly", config: {})
      end

      it "sets the compiled prompt as instructions and uses the prompt name as trace_name" do
        allow(fake_prompt_store).to receive(:get_prompt).and_return(fake_prompt)

        expect(fake_observer).to receive(:observe).with(
          "text-to-speech",
          hash_including(trace_name: "tts-prompt", prompt: fake_prompt)
        ).and_yield(fake_generation)

        expect(fake_speech).to receive(:create).with(
          hash_including(instructions: "speak softly")
        ).and_return(fake_tts_response)

        expect(fake_upload_handler).to receive(:upload)

        handler.create(message: "say hi", parameters: { prompt_name: "tts-prompt" })
      end

      it "merges prompt.config into parameters by default" do
        prompt_with_config = double(
          "Prompt", type: "text", name: "tts-prompt", compile: "speak", config: { voice: "echo" }
        )
        allow(fake_prompt_store).to receive(:get_prompt).and_return(prompt_with_config)

        expect(fake_observer).to receive(:observe).and_yield(fake_generation)

        expect(fake_speech).to receive(:create).with(
          hash_including(voice: "echo")
        ).and_return(fake_tts_response)

        expect(fake_upload_handler).to receive(:upload)

        handler.create(message: "say hi", parameters: { prompt_name: "tts-prompt", voice: "alloy" })
      end

      it "skips merging prompt.config when prompt_config_disabled is true" do
        prompt_with_config = double(
          "Prompt", type: "text", name: "tts-prompt", compile: "speak", config: { voice: "echo" }
        )
        allow(fake_prompt_store).to receive(:get_prompt).and_return(prompt_with_config)

        expect(fake_observer).to receive(:observe).and_yield(fake_generation)

        expect(fake_speech).to receive(:create).with(
          hash_including(voice: "alloy")
        ).and_return(fake_tts_response)

        expect(fake_upload_handler).to receive(:upload)

        handler.create(
          message: "say hi",
          parameters: { prompt_name: "tts-prompt", prompt_config_disabled: true, voice: "alloy" }
        )
      end

      it "raises if the prompt is not a text prompt" do
        non_text_prompt = double("Prompt", type: "chat", name: "tts-prompt")
        allow(fake_prompt_store).to receive(:get_prompt).and_return(non_text_prompt)

        expect do
          handler.create(message: "say hi", parameters: { prompt_name: "tts-prompt" })
        end.to raise_error(described_class::ObservedTextToSpeechPromptError)
      end
    end
  end
end
