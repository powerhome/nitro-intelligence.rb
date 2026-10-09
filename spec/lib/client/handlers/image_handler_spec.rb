require "spec_helper"
require "nitro_intelligence/client/handlers/image_handler"

RSpec.describe NitroIntelligence::Client::Handlers::ImageHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, chat: fake_chat) }
  let(:fake_chat) { double("Chat", completions: fake_completions) }
  let(:fake_completions) { double("Completions") }

  let(:handler) { described_class.new(client: fake_openai_client) }
  let(:fake_image_generation) do
    instance_double(
      NitroIntelligence::ImageGeneration,
      messages: [],
      edit?: false,
      config: double("Config", model: "custom-model", aspect_ratio: "16:9", resolution: "1024x1024"),
      parse_file: nil
    )
  end

  before do
    allow(NitroIntelligence::ImageGeneration).to receive(:new).and_yield(double.as_null_object).and_return(fake_image_generation)

    fake_catalog = double("ModelCatalog")
    allow(fake_catalog).to receive(:exists?).and_return(true)
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)
  end

  describe "#create" do
    it "generates an image using OpenAI chat completions" do
      expect(fake_completions).to receive(:create).with(
        hash_including(
          model: "custom-model",
          request_options: {
            extra_body: {
              image_config: { aspect_ratio: "16:9", image_size: "1024x1024" },
            },
            extra_headers: { "nip-modality" => "image", "nip-requested-model" => "custom-model" },
          }
        )
      ).and_return("fake_chat_completion")

      expect(fake_image_generation).to receive(:parse_file).with("fake_chat_completion")

      response = handler.create(message: "draw a cat", parameters: { model: "custom-model" })
      expect(response).to eq(fake_image_generation)
    end
  end
end

require_relative "../../../support/image_edit_context"

RSpec.describe NitroIntelligence::Client::Handlers::ImageHandler, "image edits" do
  include_context "image edit client"

  subject(:handler) { described_class.new(client: real_client) }

  let(:image_generation) do
    NitroIntelligence::ImageGeneration.new(message: "Replace the siding", target_image: house_bytes, reference_images: [swatch_bytes])
  end

  it "uploads ordered images with their MIME types and standard edit fields" do
    request = stub_request(:post, "https://gateway.example/v1/images/edits").with do |req|
      expect(req.headers["Content-Type"]).to start_with("multipart/form-data; boundary=")
      expect(req.body).to include('name="prompt"', "Replace the siding", 'name="size"', "1360x768", "default-image")
      expect(req.body).to include('name="image[]"; filename="image-1.png"', "Content-Type: image/png", house_bytes)
      expect(req.body).to include('name="image[]"; filename="image-2.jpeg"', "Content-Type: image/jpeg", swatch_bytes)
      expect(req.body.index(house_bytes)).to be < req.body.index(swatch_bytes)
      expect(req.body).not_to include("image_config", "aspect_ratio", "resolution", "messages", "sync_mode")
      true
    end.to_return(headers: { "content-type" => "application/json" }, body: { created: 1, data: [] }.to_json)
    parameters = {}
    handler.validate_and_resolve!(parameters, image_generation)

    expect(handler.perform_request(parameters:)).to be_a(OpenAI::Models::ImagesResponse)
    expect(request).to have_been_requested.once
  end

  it "rejects a blank edit prompt before making a request" do
    parameters = { prompt: " " }
    handler.validate_and_resolve!(parameters, image_generation)

    expect { handler.perform_request(parameters:) }.to raise_error(ArgumentError, /requires a message/)
  end

  it "rejects chat-only settings rather than silently dropping them" do
    parameters = { temperature: 0.5 }
    handler.validate_and_resolve!(parameters, image_generation)

    expect { handler.perform_request(parameters:) }.to raise_error(ArgumentError, /temperature/)
  end
end

RSpec.describe NitroIntelligence::Client::Handlers::ImageHandler, "edit responses" do
  include_context "image edit client"

  subject(:handler) { described_class.new(client: real_client) }

  %i[b64_json data_url https_url].each do |format|
    it "returns the same image bytes for #{format}" do
      base64 = Base64.strict_encode64(house_bytes)
      payload = case format
                when :b64_json then { b64_json: base64 }
                when :data_url then { url: "data:image/png;base64,#{base64}" }
                when :https_url then { url: "https://images.example/result.png" }
                end
      stub_request(:get, "https://images.example/result.png").to_return(body: house_bytes)
      stub_request(:post, "https://gateway.example/v1/images/edits").to_return(
        headers: { "content-type" => "application/json" }, body: { created: 1, data: [payload] }.to_json
      )

      result = handler.create(message: "Replace the siding", target_image: house_bytes, reference_images: [swatch_bytes])

      expect(result).to be_a(NitroIntelligence::ImageGeneration)
      expect(result.generated_image.byte_string).to eq(house_bytes)
      expect(result.generated_image.mime_type).to eq("image/png")
      expect(result.generated_image.file_extension).to eq("png")
      expect(result.generated_image.direction).to eq("output")
    end
  end

  [[], [{}]].each do |data|
    it "raises a clear error for an empty image response #{data.inspect}" do
      stub_request(:post, "https://gateway.example/v1/images/edits").to_return(
        headers: { "content-type" => "application/json" }, body: { created: 1, data: }.to_json
      )

      expect { handler.create(message: "Edit", target_image: house_bytes) }
        .to raise_error(NitroIntelligence::ImageGeneration::ImageResponseError)
    end
  end

  it "does not swallow malformed edit image data" do
    stub_request(:post, "https://gateway.example/v1/images/edits").to_return(
      headers: { "content-type" => "application/json" }, body: { created: 1, data: [{ b64_json: "invalid base64" }] }.to_json
    )

    expect { handler.create(message: "Edit", target_image: house_bytes) }.to raise_error(ArgumentError, /base64/)
  end
end
