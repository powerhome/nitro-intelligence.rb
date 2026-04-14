require "spec_helper"
require "nitro_intelligence/client/handlers/observed/image_handler"

RSpec.describe NitroIntelligence::Client::Handlers::Observed::ImageHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, chat: fake_chat) }
  let(:fake_chat) { double("Chat", completions: fake_completions) }
  let(:fake_completions) { double("Completions") }

  let(:base_handler) { NitroIntelligence::Client::Handlers::ImageHandler.new(client: fake_openai_client) }

  let(:fake_prompt_store) { double("PromptStore") }
  let(:fake_project) { double("Project", slug: "test-project", prompt_store: fake_prompt_store, auth_token: "auth_token") }
  let(:fake_upload_handler) { double("UploadHandler", auth_token: "auth_token", upload: nil, replace_base64_with_media_references: nil) }
  let(:fake_project_client) { double("ProjectClient", project: fake_project) }
  let(:fake_observer) { double("LangfuseObserver", project_client: fake_project_client) }

  let(:handler) { described_class.new(base_handler:, observer: fake_observer) }

  let(:fake_image_config) do
    double("Config", model: "dall-e-3", aspect_ratio: "16:9", resolution: "1024x1024")
  end

  let(:fake_generated_file) { double("GeneratedFile", byte_string: "byte_string", mime_type: "image/jpeg", direction: "input") }

  let(:fake_image_generation) do
    instance_double(
      NitroIntelligence::ImageGeneration,
      messages: [{ role: "user", content: "draw a cat" }],
      config: fake_image_config,
      parse_file: nil,
      files: [fake_generated_file],
      :trace_id= => nil,
      trace_id: "trace-999"
    )
  end

  before do
    allow(NitroIntelligence::ImageGeneration).to receive(:new).and_yield(double.as_null_object).and_return(fake_image_generation)

    # Mock UploadHandler to avoid real HTTP calls
    allow(NitroIntelligence::Observability::UploadHandler).to receive(:new).and_return(
      fake_upload_handler
    )

    fake_catalog = double("ModelCatalog")
    allow(fake_catalog).to receive(:exists?).and_return(true)
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)
  end

  describe "#create" do
    let(:fake_completion_response) do
      double("CompletionResponse",
             model: "dall-e-3",
             choices: [double(message: double(to_h: { "content" => "base64_image_data_here" }))],
             usage: double(prompt_tokens: 15, completion_tokens: 30, total_tokens: 45))
    end

    let(:fake_generation) { double("Generation", trace_id: "trace-999") }

    it "observes the request, handles uploads, and builds trace attributes" do
      expect(fake_observer).to receive(:observe).with(
        "image-generation",
        hash_including(type: :generation, trace_name: "test-project", prompt: nil)
      ).and_yield(fake_generation)

      expect(fake_completions).to receive(:create).with(
        hash_including(
          model: "dall-e-3",
          request_options: hash_including(:extra_body)
        )
      ).and_return(fake_completion_response)

      expect(fake_image_generation).to receive(:trace_id=).with("trace-999")
      expect(fake_image_generation).to receive(:parse_file).with(fake_completion_response)

      expect(fake_upload_handler).to receive(:upload).with("trace-999", upload_queue: instance_of(Queue))
      expect(fake_upload_handler).to receive(:replace_base64_with_media_references).twice

      # FIX: Removed array destructuring (trace_attributes) since the handler just returns the image object
      image_generation_result = handler.create(message: "draw a cat")

      expect(image_generation_result).to eq(fake_image_generation)
    end

    context "with custom metadata" do
      it "passes custom metadata through to the observer" do
        expect(fake_observer).to receive(:observe).with(
          "image-generation",
          hash_including(
            type: :generation,
            parameters: hash_including(metadata: { custom_key: "custom_value" }),
            trace_name: "test-project",
            prompt: nil
          )
        ).and_yield(fake_generation)

        expect(fake_completions).to receive(:create).and_return(fake_completion_response)

        expect(fake_image_generation).to receive(:trace_id=).with("trace-999")
        expect(fake_image_generation).to receive(:parse_file).with(fake_completion_response)

        expect(fake_upload_handler).to receive(:upload).with("trace-999", upload_queue: instance_of(Queue))
        expect(fake_upload_handler).to receive(:replace_base64_with_media_references).twice

        handler.create(message: "draw a cat", parameters: { metadata: { custom_key: "custom_value" } })
      end
    end

    context "with a prompt" do
      let(:fake_prompt) do
        double("Prompt", name: "test-image-prompt", config: { temperature: 0.8 })
      end

      it "interpolates the prompt and applies config before observing" do
        allow(fake_prompt_store).to receive(:get_prompt).and_return(fake_prompt)
        expect(fake_prompt).to receive(:interpolate).and_return([{ role: "user", content: "interpolated cat drawing prompt" }])

        expect(fake_observer).to receive(:observe).with(
          "image-generation",
          hash_including(trace_name: "test-image-prompt", prompt: fake_prompt)
        ).and_yield(fake_generation)

        expect(fake_completions).to receive(:create).with(
          hash_including(
            messages: [{ role: "user", content: "interpolated cat drawing prompt" }],
            temperature: 0.8
          )
        ).and_return(fake_completion_response)

        expect(fake_image_generation).to receive(:trace_id=).with("trace-999")
        expect(fake_image_generation).to receive(:parse_file).with(fake_completion_response)

        expect(fake_upload_handler).to receive(:upload).with("trace-999", upload_queue: instance_of(Queue))
        expect(fake_upload_handler).to receive(:replace_base64_with_media_references).twice

        handler.create(message: "draw a cat", parameters: { prompt_name: "test-image-prompt" })
      end
    end
  end
end
