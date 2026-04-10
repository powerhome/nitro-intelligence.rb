require "spec_helper"
require "nitro_intelligence/client/base"

RSpec.describe NitroIntelligence::Client::Base do
  let(:fake_openai_client) { instance_double(OpenAI::Client) }
  let(:base_client) { described_class.new(client: fake_openai_client) }

  describe "delegation to handlers" do
    it "delegates #chat to the ChatHandler" do
      mock_handler = instance_double(NitroIntelligence::Client::Handlers::ChatHandler)
      allow(NitroIntelligence::Client::Handlers::ChatHandler).to receive(:new).with(client: fake_openai_client).and_return(mock_handler)

      expect(mock_handler).to receive(:create).with(message: "hello", parameters: {})
      base_client.chat(message: "hello")
    end

    it "delegates #generate_image to the ImageHandler" do
      mock_handler = instance_double(NitroIntelligence::Client::Handlers::ImageHandler)
      allow(NitroIntelligence::Client::Handlers::ImageHandler).to receive(:new).with(client: fake_openai_client).and_return(mock_handler)

      expect(mock_handler).to receive(:create).with(message: "draw", target_image: nil, reference_images: [], parameters: {})
      base_client.generate_image(message: "draw")
    end

    it "delegates #transcribe_audio to the AudioTranscriptionHandler" do
      mock_handler = instance_double(NitroIntelligence::Client::Handlers::AudioTranscriptionHandler)
      allow(NitroIntelligence::Client::Handlers::AudioTranscriptionHandler).to receive(:new).with(client: fake_openai_client).and_return(mock_handler)

      expect(mock_handler).to receive(:create).with(message: "transcribe", audio_file: nil, parameters: {})
      base_client.transcribe_audio(message: "transcribe")
    end
  end

  describe "method_missing delegation" do
    it "defers unknown methods to the OpenAI client" do
      expect(fake_openai_client).to receive(:models)
      base_client.models
    end

    it "responds to methods defined on the OpenAI client" do
      allow(fake_openai_client).to receive(:respond_to?).with(:models, false).and_return(true)
      expect(base_client.respond_to?(:models)).to be true
    end
  end
end
