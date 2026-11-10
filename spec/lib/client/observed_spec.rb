require "spec_helper"
require "nitro_intelligence/client/observed"

RSpec.describe NitroIntelligence::Client::Observed do
  let(:fake_openai_client) { instance_double(OpenAI::Client) }
  let(:fake_observer) { double("LangfuseObserver") }

  let(:observed_client) { described_class.new(client: fake_openai_client, observer: fake_observer) }

  describe "#prompt" do
    it "fetches the prompt from the observer's project" do
      prompt = instance_double(NitroIntelligence::Observability::Prompt)
      project = instance_double(NitroIntelligence::Observability::Project)
      allow(fake_observer).to receive(:project_client).and_return(double("ProjectClient", project:))
      allow(project).to receive(:prompt).with("Page Finder Search", label: "staging", version: nil).and_return(prompt)

      expect(observed_client.prompt("Page Finder Search", label: "staging")).to be(prompt)
    end
  end

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

    it "delegates #text_to_speech to the Observed::TextToSpeechHandler" do
      mock_handler = instance_double(NitroIntelligence::Client::Handlers::Observed::TextToSpeechHandler)
      allow(NitroIntelligence::Client::Handlers::Observed::TextToSpeechHandler)
        .to receive(:new).with(base_handler: instance_of(NitroIntelligence::Client::Handlers::TextToSpeechHandler), observer: fake_observer)
        .and_return(mock_handler)

      expect(mock_handler).to receive(:create).with(message: "say hi", parameters: {})
      observed_client.text_to_speech(message: "say hi")
    end

    it "delegates #decide to the Observed::DecisionHandler" do
      mock_handler = instance_double(NitroIntelligence::Client::Handlers::Observed::DecisionHandler)
      allow(NitroIntelligence::Client::Handlers::Observed::DecisionHandler)
        .to receive(:new).with(base_handler: instance_of(NitroIntelligence::Client::Handlers::DecisionHandler), observer: fake_observer)
        .and_return(mock_handler)

      expect(mock_handler).to receive(:create).with(state: "content", questions: { q: { type: "noul" } }, parameters: {})
      observed_client.decide(state: "content", questions: { q: { type: "noul" } })
    end

    it "delegates #embed_query and #embed_documents to the Observed::EmbeddingHandler" do
      mock_handler = instance_double(NitroIntelligence::Client::Handlers::Observed::EmbeddingHandler)
      allow(NitroIntelligence::Client::Handlers::Observed::EmbeddingHandler)
        .to receive(:new).with(base_handler: instance_of(NitroIntelligence::Client::Handlers::EmbeddingHandler), observer: fake_observer)
        .and_return(mock_handler)

      expect(mock_handler).to receive(:create).with(input: "q", input_type: :query, parameters: {})
      expect(mock_handler).to receive(:create).with(input: ["a"], input_type: :document, parameters: {})
      observed_client.embed_query(query: "q")
      observed_client.embed_documents(documents: ["a"])
    end

    it "delegates #rerank to the Observed::RerankHandler" do
      mock_handler = instance_double(NitroIntelligence::Client::Handlers::Observed::RerankHandler)
      allow(NitroIntelligence::Client::Handlers::Observed::RerankHandler)
        .to receive(:new).with(base_handler: instance_of(NitroIntelligence::Client::Handlers::RerankHandler), observer: fake_observer)
        .and_return(mock_handler)

      expect(mock_handler).to receive(:create).with(query: "q", documents: ["a"], parameters: {})
      observed_client.rerank(query: "q", documents: ["a"])
    end
  end
end
