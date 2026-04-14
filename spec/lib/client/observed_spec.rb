require "spec_helper"
require "nitro_intelligence/client/observed"

RSpec.describe NitroIntelligence::Client::Observed do
  let(:fake_openai_client) { instance_double(OpenAI::Client) }
  let(:fake_observer) { double("LangfuseObserver") }

  let(:observed_client) { described_class.new(client: fake_openai_client, observer: fake_observer) }

  describe "delegation to observed handlers" do
    it "delegates #chat to the Observed::ChatHandler" do
      mock_handler = instance_double(NitroIntelligence::Client::Handlers::Observed::ChatHandler)
      allow(NitroIntelligence::Client::Handlers::Observed::ChatHandler)
        .to receive(:new).with(base_handler: instance_of(NitroIntelligence::Client::Handlers::ChatHandler), observer: fake_observer)
        .and_return(mock_handler)

      expect(mock_handler).to receive(:create).with(message: "hello", parameters: {})
      observed_client.chat(message: "hello")
    end

    it "delegates #generate_image to the Observed::ImageHandler" do
      mock_handler = instance_double(NitroIntelligence::Client::Handlers::Observed::ImageHandler)
      allow(NitroIntelligence::Client::Handlers::Observed::ImageHandler)
        .to receive(:new).with(base_handler: instance_of(NitroIntelligence::Client::Handlers::ImageHandler), observer: fake_observer)
        .and_return(mock_handler)

      expect(mock_handler).to receive(:create).with(message: "draw", target_image: nil, reference_images: [], parameters: {})
      observed_client.generate_image(message: "draw")
    end

    it "delegates #transcribe_audio to the Observed::AudioTranscriptionHandler" do
      mock_handler = instance_double(NitroIntelligence::Client::Handlers::Observed::AudioTranscriptionHandler)
      allow(NitroIntelligence::Client::Handlers::Observed::AudioTranscriptionHandler)
        .to receive(:new).with(base_handler: instance_of(NitroIntelligence::Client::Handlers::AudioTranscriptionHandler), observer: fake_observer)
        .and_return(mock_handler)

      expect(mock_handler).to receive(:create).with(message: "transcribe", audio_file: nil, parameters: {})
      observed_client.transcribe_audio(message: "transcribe")
    end
  end
end
