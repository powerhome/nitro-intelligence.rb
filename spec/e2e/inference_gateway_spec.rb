require "tempfile"
require_relative "e2e_helper"

RSpec.describe "Inference gateway, end to end", :e2e do
  subject(:client) { NitroIntelligence::Client.new(inference_timeout: 120) }

  describe "#chat" do
    let(:response) do
      client.chat(
        message: "Reply with the single word pong and nothing else.",
        parameters: { max_tokens: 1000, metadata: e2e_metadata }
      )
    end

    it "answers the message" do
      expect(response.choices.first.message.content).to match(/pong/i)
      expect(response.usage.total_tokens).to be_positive
    end

    it "returns the gateway headers the observer reads cost and call IDs from" do
      headers = response.last_response.headers

      expect(Float(headers["x-litellm-response-cost"])).to be_positive
      expect(headers["x-litellm-call-id"]).to be_present
      expect(headers["x-litellm-model-group"]).to eq(E2eHelpers::TEXT_MODEL)
    end
  end

  describe "#decide" do
    it "answers yes/no questions with probabilities that fit the content" do
      decision = client.decide(
        state: "I was charged twice for my order. Please refund one of the payments.",
        questions: {
          billing: { type: "noul", instructions: "Is this message about billing or payments?" },
          weather: { type: "noul", instructions: "Is this message about the weather?" },
        },
        parameters: { metadata: e2e_metadata }
      )

      # The response names the dated snapshot that served it, such as typesafe/jev-1.14-20261014.
      expect(decision.model).to start_with(E2eHelpers::DECISION_MODEL)
      expect(decision.answers[:billing].noul).to be > 0.5
      expect(decision.answers[:weather].noul).to be < 0.5
    end
  end

  describe "#embed_query and #embed_documents" do
    it "places a query closer to the document that answers it" do
      documents = client.embed_documents(
        documents: [
          "To request time off, submit a PTO request in the HR portal for your manager to approve.",
          "The cafeteria on the second floor serves lunch from noon until two.",
        ],
        parameters: { metadata: e2e_metadata }
      ).vectors
      query = client.embed_query(query: "How do I book vacation days?",
                                 parameters: { metadata: e2e_metadata }).vector

      expect(documents.map(&:size)).to all(eq(query.size))
      expect(cosine_similarity(query, documents[0])).to be > cosine_similarity(query, documents[1])
    end
  end

  describe "#rerank" do
    it "scores the relevant document highest" do
      ranking = client.rerank(
        query: "How do I book vacation days?",
        documents: [
          "The cafeteria on the second floor serves lunch from noon until two.",
          "To request time off, submit a PTO request in the HR portal for your manager to approve.",
          "Parking passes are issued by building security.",
        ],
        parameters: { metadata: e2e_metadata }
      )

      expect(ranking.results.max_by(&:relevance_score).index).to eq(1)
    end
  end

  describe "#text_to_speech and #transcribe_audio" do
    let(:sentence) { "The quick brown fox jumps over the lazy dog." }

    it "speaks text that transcribes back to the same words" do
      audio = client.text_to_speech(message: sentence, parameters: { metadata: e2e_metadata })

      Tempfile.create(["speech", ".wav"], binmode: true) do |file|
        file.write(audio.string)
        file.rewind

        transcription = client.transcribe_audio(audio_file: file, parameters: { metadata: e2e_metadata })

        expect(words(transcription.text)).to include("quick", "brown", "fox", "lazy", "dog")
      end
    end
  end

  describe "#generate_image" do
    it "returns a generated image" do
      result = client.generate_image(
        message: "A plain red square on a white background.",
        parameters: { aspect_ratio: "1:1", resolution: "512", metadata: e2e_metadata }
      )

      expect(result.generated_image.mime_type).to start_with("image/")
      expect(result.generated_image.width).to be_positive
      expect(result.generated_image.height).to be_positive
    end
  end
end
