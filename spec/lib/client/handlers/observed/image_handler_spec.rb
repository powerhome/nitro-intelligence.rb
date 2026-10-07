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
      edit?: false,
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

    # #create returns the image generation rather than the observation payload, so the
    # trace attributes are only reachable from inside the observer's block.
    def trace_attributes_for(completion_response)
      captured = nil
      allow(fake_observer).to receive(:observe) do |*, **, &block|
        _result, captured = block.call(fake_generation)
      end
      expect(fake_completions).to receive(:create).and_return(completion_response)

      handler.create(message: "draw a cat")

      captured
    end

    it "carries the cost the gateway reported into the trace attributes" do
      priced_response = double(
        "CompletionResponse",
        model: "dall-e-3",
        choices: [double(message: double(to_h: { "content" => "base64_image_data_here" }))],
        usage: double(prompt_tokens: 15, completion_tokens: 30, total_tokens: 45),
        last_response: double("LastResponse", headers: {
                                "x-litellm-response-cost" => "5.85e-06",
                                "x-litellm-response-cost-input" => "1.1e-06",
                                "x-litellm-response-cost-output" => "4.75e-06",
                              })
      )

      expect(trace_attributes_for(priced_response)[:cost_details]).to eq(total: 5.85e-06, input: 1.1e-06, output: 4.75e-06)
    end

    it "leaves the cost unset when the gateway did not price the request" do
      # A deployment the gateway has no price for sends no cost header at all.
      expect(trace_attributes_for(fake_completion_response)[:cost_details]).to be_nil
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

require_relative "../../../../support/image_edit_context"

RSpec.describe NitroIntelligence::Client::Handlers::Observed::ImageHandler, "edit prompts" do
  include_context "image edit client"

  let(:base_handler) { NitroIntelligence::Client::Handlers::ImageHandler.new(client: real_client) }
  let(:store) { double("PromptStore", get_prompt: prompt) }
  let(:project) { double("Project", slug: "home-studio", prompt_store: store) }
  let(:observer) { double("Observer", project_client: double("ProjectClient", project:)) }
  let(:handler) { described_class.new(base_handler:, observer:) }
  let(:prompt) do
    NitroIntelligence::Observability::Prompt.new(
      name: "Siding Visualizer", type: "text", prompt: "Use {{color}} siding", version: 2,
      config: { model: "other-image", size: "2048x1536" }
    )
  end

  it "compiles the prompt and applies its model and size before preparing the edit" do
    expect(observer).to receive(:observe).with(
      "image-generation",
      hash_including(prompt:, trace_name: "Siding Visualizer", parameters: hash_including(
        model: "other-image", size: "2048x1536", prompt: "Use blue siding\n\nKeep the roof"
      ))
    )

    handler.create(message: "Keep the roof", target_image: house_bytes, parameters: {
                     prompt_name: prompt.name, prompt_variables: { color: "blue" }, size: "1024x1024"
                   })
  end

  it "allows a Cerebro text prompt without a caller message and respects disabled config" do
    expect(observer).to receive(:observe).with(
      "image-generation",
      hash_including(parameters: hash_including(model: "default-image", size: "1024x1024", prompt: "Use red siding"))
    )

    handler.create(target_image: house_bytes, parameters: {
                     prompt_name: prompt.name, prompt_variables: { color: "red" },
                     prompt_config_disabled: true, size: "1024x1024"
                   })
  end

  it "rejects a chat prompt without flattening its roles" do
    chat_prompt = NitroIntelligence::Observability::Prompt.new(
      name: "Chat prompt", type: "chat", prompt: [{ role: "system", content: "Edit" }], version: 1
    )
    allow(store).to receive(:get_prompt).and_return(chat_prompt)

    expect { handler.create(target_image: house_bytes, parameters: { prompt_name: "Chat prompt" }) }
      .to raise_error(described_class::ObservedImagePromptError, /text prompt/)
  end
end

RSpec.describe NitroIntelligence::Client::Handlers::Observed::ImageHandler, "observed edits" do
  include_context "image edit client"

  let(:base_handler) { NitroIntelligence::Client::Handlers::ImageHandler.new(client: real_client) }
  let(:prompt) do
    NitroIntelligence::Observability::Prompt.new(
      name: "Siding Visualizer", type: "text", prompt: "Use {{color}} siding", version: 2,
      config: { model: "other-image", size: "2048x1536" }
    )
  end
  let(:store) { double("PromptStore", get_prompt: prompt) }
  let(:project) { double("Project", slug: "home-studio", prompt_store: store, auth_token: "test-cerebro-token") }
  let(:observer) { double("Observer", project_client: double("ProjectClient", project:)) }
  let(:handler) { described_class.new(base_handler:, observer:) }
  let(:trace_results) { [] }
  let(:parameters) { { prompt_name: prompt.name, prompt_variables: { color: "blue" }, metadata: { source: "preview" } } }
  let(:image_format) { :b64_json }
  let(:usage) { nil }
  let(:cost_headers) { { "x-litellm-response-cost" => "0.08" } }
  let(:image_payload) do
    case image_format
    when :b64_json then { b64_json: Base64.strict_encode64(house_bytes) }
    when :data_url then { url: "data:image/png;base64,#{Base64.strict_encode64(house_bytes)}" }
    when :https_url then { url: "https://images.example/result.png" }
    end
  end
  let(:edit_request) do
    stub_request(:post, "https://gateway.example/v1/images/edits").with(headers: {
                                                                          "nip-modality" => "image", "nip-requested-model" => "other-image",
                                                                          "x-litellm-trace-id" => "trace-123", "x-litellm-spend-logs-metadata" => '{"source":"preview"}'
                                                                        }).to_return(
                                                                          headers: { "content-type" => "application/json", **cost_headers },
                                                                          body: { created: 1, data: [image_payload], usage: }.to_json
                                                                        )
  end

  before do
    allow(NitroIntelligence.config).to receive(:observability_base_url).and_return("https://cerebro.example")
    stub_request(:get, "https://images.example/result.png").to_return(body: house_bytes)
    stub_request(:post, "https://cerebro.example/api/public/media").to_return do |request|
      body = JSON.parse(request.body)
      expect(body.fetch("traceId")).to eq("trace-123")
      { body: { mediaId: "#{body.fetch('field')}-#{body.fetch('sha256Hash')}", uploadUrl: nil }.to_json }
    end
    allow(observer).to receive(:observe) do |operation, **options, &block|
      expect(operation).to eq("image-generation")
      expect(options).to include(prompt:, trace_name: "Siding Visualizer")
      expect(options[:parameters][:model]).to eq("other-image")
      trace_results << block.call(double("Generation", trace_id: "trace-123"))
    end
    edit_request
  end

  %i[b64_json data_url https_url].each do |format|
    context "with #{format}" do
      let(:image_format) { format }

      it "preserves the result and trace while replacing images with Cerebro media references" do
        result = handler.create(target_image: house_bytes, reference_images: [swatch_bytes], parameters:)
        response, attributes = trace_results.first

        expect(result.generated_image.byte_string).to eq(house_bytes)
        expect(result.trace_id).to eq("trace-123")
        expect(attributes[:input].first[:content].first).to eq(type: "text", text: "Use blue siding")
        expect(attributes[:model_parameters]).to eq(size: "2048x1536")
        expect(attributes[:usage_details]).to be_nil
        expect(attributes[:cost_details]).to eq(total: 0.08)
        expect(attributes[:output][:images].first[:image_url][:url]).to start_with("@@@langfuseMedia:")
        expect(attributes[:input].first[:content].drop(1).map { |part| part[:image_url][:url] })
          .to all(start_with("@@@langfuseMedia:"))
        expect(attributes.to_json).not_to include(Base64.strict_encode64(house_bytes), Base64.strict_encode64(swatch_bytes))
        expect(response.data.first.to_h).to include(image_payload)
        expect(edit_request).to have_been_requested.once
      end
    end
  end

  context "with token usage" do
    let(:usage) do
      { input_tokens: 10, output_tokens: 20, total_tokens: 30, input_tokens_details: { text_tokens: 2, image_tokens: 8 } }
    end

    it "records the reported image token counts" do
      handler.create(target_image: house_bytes, parameters:)

      expect(trace_results.first.last[:usage_details]).to eq(input_tokens: 10, output_tokens: 20, total_tokens: 30)
    end
  end

  context "without a cost header" do
    let(:cost_headers) { {} }

    it "leaves cost unknown" do
      handler.create(target_image: house_bytes, parameters:)

      expect(trace_results.first.last[:cost_details]).to be_nil
    end
  end

  it "preserves gateway error metadata and does not turn a failed edit into a success" do
    stub_request(:post, "https://gateway.example/v1/images/edits").to_return(
      status: 400, headers: { "content-type" => "application/json", "x-litellm-call-id" => "failed-edit" },
      body: { error: { message: "Unsupported edit", type: "invalid_request_error" } }.to_json
    )

    expect { handler.create(target_image: house_bytes, parameters:) }.to raise_error(OpenAI::Errors::BadRequestError) { |error|
      expect(error.headers["x-litellm-call-id"]).to eq("failed-edit")
    }
    expect(trace_results).to be_empty
  end
end
