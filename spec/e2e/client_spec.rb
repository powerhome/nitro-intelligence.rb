require "tempfile"
require_relative "e2e_helper"

# Each request goes through an observed client, as an application's does, and is checked end to end:
# the answer, the trace Cerebro recorded for it, and the cost the gateway charged, which the trace
# must carry exactly.
RSpec.describe NitroIntelligence::Client, :e2e do
  subject(:client) do
    described_class.new(observability_project_slug: E2eHelpers::OBSERVABILITY_PROJECT_SLUG, inference_timeout: 120)
  end

  let(:trace_seed) { new_trace_seed }
  let(:trace_id) { NitroIntelligence::Trace.create_id(seed: trace_seed) }
  let(:trace_name) { "nitro-intelligence.rb e2e: #{RSpec.current_example.description}" }
  let(:user_id) { "nitro-intelligence.rb-e2e" }
  let(:session_id) { "nitro-intelligence.rb-e2e-#{ENV.fetch('GITHUB_RUN_ID', 'local')}" }
  let(:tags) { %w[e2e nitro-intelligence.rb] }
  # Everything that groups a request's trace in Cerebro.
  let(:trace_parameters) { { trace_seed:, trace_name:, user_id:, session_id:, tags:, metadata: e2e_metadata } }

  # Reads back the trace once each named observation has finished and been priced or, for a failed
  # request, marked as failed.
  def recorded_trace(*names)
    flush_observations
    cerebro.observations(trace_id) do |observations|
      names.all? do |name|
        observation = observations.find { _1["name"] == name }
        observation && observation["endTime"] &&
          (observation.dig("costDetails", "total") || observation["level"] == "ERROR")
      end
    end
  end

  # Each request is a trace of its own, grouped and named as the request asked.
  def expect_request(observation, name:, type: "GENERATION")
    expect(observation).to include(
      "name" => name,
      "type" => type,
      "traceId" => trace_id,
      "parentObservationId" => nil,
      "level" => "DEFAULT",
      "environment" => NitroIntelligence.environment,
      "traceName" => trace_name,
      "userId" => user_id,
      "sessionId" => session_id
    )
    expect(observation["tags"]).to match_array(tags)
    expect_metadata(observation, e2e_metadata)
  end

  describe "#chat" do
    it "answers the message and records the completion with its usage and cost" do
      response = client.chat(
        message: "Reply with the single word pong and nothing else.",
        parameters: { max_tokens: 1000, **trace_parameters }
      )

      expect(response.choices.first.message.content).to match(/pong/i)
      expect(response.last_response.headers["x-litellm-model-group"]).to eq(E2eHelpers::TEXT_MODEL)

      generation = observation_named(recorded_trace("chat-completion"), "chat-completion")
      expect_request(generation, name: "chat-completion")
      expect(generation["model"]).to eq(response.model)
      expect(CerebroReader.parse(generation["input"])).to eq(
        [{ "role" => "user", "content" => "Reply with the single word pong and nothing else." }]
      )
      expect(CerebroReader.parse(generation["output"])).to include("role" => "assistant",
                                                                   "content" => a_string_matching(/pong/i))
      expect_usage(generation, total: response.usage.total_tokens)
      expect_cost(generation, gateway_cost(response))
    end

    context "with a prompt managed in Cerebro" do
      let(:prompt_name) { "nitro-intelligence.rb e2e" }
      let(:prompt) do
        {
          name: prompt_name,
          type: "chat",
          prompt: [
            { role: "system", content: "You answer with exactly one word." },
            { role: "user", content: "Reply with the single word {{word}} and nothing else." },
          ],
          config: { max_tokens: 1000 },
          labels: ["production"],
        }
      end

      # Creates the prompt only when the project's production version differs, so runs share one
      # version instead of adding one each.
      def production_prompt_version
        current = cerebro.prompt(prompt_name, label: "production")
        if current&.slice("type", "prompt", "config") == prompt.slice(:type, :prompt, :config).deep_stringify_keys
          return current.fetch("version")
        end

        cerebro.create_prompt(prompt).fetch("version")
      end

      it "compiles the prompt, applies its config and links the completion to its version" do
        version = production_prompt_version

        response = client.chat(parameters: { prompt_name:, prompt_variables: { word: "pong" }, **trace_parameters })

        expect(response.choices.first.message.content).to match(/pong/i)

        generation = observation_named(recorded_trace("chat-completion"), "chat-completion")
        expect_request(generation, name: "chat-completion")
        expect(generation).to include("promptName" => prompt_name, "promptVersion" => version)
        expect(CerebroReader.parse(generation["input"])).to eq(
          [
            { "role" => "system", "content" => "You answer with exactly one word." },
            { "role" => "user", "content" => "Reply with the single word pong and nothing else." },
          ]
        )
        expect_metadata(generation, prompt_name:, prompt_version: version)
        expect_usage(generation, total: response.usage.total_tokens)
        expect_cost(generation, gateway_cost(response))
      end
    end

    context "with a project that masks content" do
      subject(:client) do
        described_class.new(observability_project_slug: E2eHelpers::MASKED_OBSERVABILITY_PROJECT_SLUG,
                            inference_timeout: 120)
      end

      it "records the completion's usage and cost but none of its content" do
        response = client.chat(
          message: "Reply with the single word pong and nothing else.",
          parameters: { max_tokens: 1000, **trace_parameters }
        )

        expect(response.choices.first.message.content).to match(/pong/i)

        generation = observation_named(recorded_trace("chat-completion"), "chat-completion")
        expect_request(generation, name: "chat-completion")
        expect(CerebroReader.parse(generation["input"])).to eq("[masked]")
        expect(CerebroReader.parse(generation["output"])).to eq("[masked]")
        expect_usage(generation, total: response.usage.total_tokens)
        expect_cost(generation, gateway_cost(response))
      end
    end

    context "when the gateway refuses the request" do
      it "raises, and records the failure with the gateway's call ID" do
        expect do
          client.chat(message: "Reply with the single word pong.",
                      parameters: { model: E2eHelpers::UNKNOWN_MODEL, **trace_parameters })
        end.to raise_error(OpenAI::Errors::APIStatusError)

        generation = observation_named(recorded_trace("chat-completion"), "chat-completion")
        expect(generation).to include("traceName" => trace_name, "model" => E2eHelpers::UNKNOWN_MODEL,
                                      "level" => "ERROR", "statusMessage" => a_string_starting_with("OpenAI::Errors::"))
        expect(CerebroReader.parse(generation["input"])).to eq(
          [{ "role" => "user", "content" => "Reply with the single word pong." }]
        )
        expect(generation.fetch("metadata")["litellm_call_id"]).to be_present
      end
    end
  end

  describe "#decide" do
    it "answers yes/no questions with probabilities that fit the content, and records the decision" do
      state = "I was charged twice for my order. Please refund one of the payments."
      decision = client.decide(
        state:,
        questions: {
          billing: { type: "noul", instructions: "Is this message about billing or payments?" },
          weather: { type: "noul", instructions: "Is this message about the weather?" },
        },
        parameters: trace_parameters
      )

      # The response names the dated snapshot that served it, such as typesafe/jev-1.14-20261014.
      expect(decision.model).to start_with(E2eHelpers::DECISION_MODEL)
      expect(decision.answers[:billing].noul).to be > 0.5
      expect(decision.answers[:weather].noul).to be < 0.5

      generation = observation_named(recorded_trace("decision"), "decision")
      expect_request(generation, name: "decision")
      expect(generation["model"]).to eq(decision.model)
      expect(CerebroReader.parse(generation["input"])).to include("state" => state)
      expect(CerebroReader.parse(generation["output"]).keys).to contain_exactly("billing", "weather")
      expect_usage(generation, total: decision.usage[:input_tokens] + decision.usage[:output_tokens])
      expect_cost(generation, gateway_cost(decision))
    end
  end

  describe "#embed_query and #embed_documents" do
    it "places a query closer to the document that answers it, and records each call as an embedding" do
      documents = client.embed_documents(
        documents: [
          "To request time off, submit a PTO request in the HR portal for your manager to approve.",
          "The cafeteria on the second floor serves lunch from noon until two.",
        ],
        parameters: trace_parameters
      )
      query = client.embed_query(query: "How do I book vacation days?", parameters: trace_parameters)

      expect(documents.vectors.map(&:size)).to all(eq(query.vector.size))
      expect(cosine_similarity(query.vector, documents.vectors[0]))
        .to be > cosine_similarity(query.vector, documents.vectors[1])

      observations = recorded_trace("embed-documents", "embed-query")
      { "embed-documents" => documents, "embed-query" => query }.each do |name, embeddings|
        embedding = observation_named(observations, name)
        expect_request(embedding, name:, type: "EMBEDDING")
        expect(embedding["model"]).to eq(embeddings.model)
        expect(CerebroReader.parse(embedding["output"])).to eq(
          "count" => embeddings.vectors.size, "dimensions" => query.vector.size
        )
        expect_usage(embedding, total: embeddings.usage[:total_tokens])
        expect_cost(embedding, embeddings.responses.sum { gateway_cost(_1) })
      end
      # The query is embedded with the model's query instruction, and Cerebro records what the model saw.
      expect(CerebroReader.parse(observation_named(observations, "embed-query")["input"]))
        .to start_with("Instruct:").and(end_with("How do I book vacation days?"))
    end
  end

  describe "#rerank" do
    it "scores the relevant document highest, and records the ranking" do
      documents = [
        "The cafeteria on the second floor serves lunch from noon until two.",
        "To request time off, submit a PTO request in the HR portal for your manager to approve.",
        "Parking passes are issued by building security.",
      ]
      ranking = client.rerank(query: "How do I book vacation days?", documents:, parameters: trace_parameters)

      expect(ranking.results.max_by(&:relevance_score).index).to eq(1)

      generation = observation_named(recorded_trace("rerank"), "rerank")
      expect_request(generation, name: "rerank")
      expect(generation["model"]).to eq(E2eHelpers::RERANK_MODEL)
      expect(CerebroReader.parse(generation["input"])).to eq(
        "query" => "How do I book vacation days?", "documents" => documents
      )
      expect(CerebroReader.parse(generation["output"]).max_by { _1["relevance_score"] }).to include("index" => 1)
      expect(generation.dig("usageDetails", "total")).to be_positive
      expect_cost(generation, gateway_cost(ranking))
    end
  end

  describe "#text_to_speech and #transcribe_audio" do
    let(:sentence) { "The quick brown fox jumps over the lazy dog." }

    it "speaks text that transcribes back to the same words, and records both requests in one trace" do
      audio = client.text_to_speech(message: sentence, parameters: trace_parameters)

      transcription = Tempfile.create(["speech", ".wav"], binmode: true) do |file|
        file.write(audio.string)
        file.rewind
        client.transcribe_audio(audio_file: file, parameters: trace_parameters)
      end

      expect(words(transcription.text)).to include("quick", "brown", "fox", "lazy", "dog")

      observations = recorded_trace("text-to-speech", "audio-transcription")

      speech = observation_named(observations, "text-to-speech")
      expect_request(speech, name: "text-to-speech")
      expect(speech["model"]).to eq(E2eHelpers::TEXT_TO_SPEECH_MODEL)
      expect(CerebroReader.parse(speech["input"])).to eq(sentence)
      # The audio is uploaded to Cerebro, and the output refers to it.
      expect(CerebroReader.parse(speech["output"])).to match(%r{\A@@@langfuseMedia:type=audio/[^|]+\|id=[^|]+\|source=bytes@@@\z})
      # The audio response carries no headers the caller can read, so the cost is checked for presence.
      expect(speech.dig("costDetails", "total")).to be_positive

      recognition = observation_named(observations, "audio-transcription")
      expect_request(recognition, name: "audio-transcription")
      expect(recognition["model"]).to eq(E2eHelpers::AUDIO_TRANSCRIPTION_MODEL)
      expect(CerebroReader.parse(recognition["output"])).to eq(transcription.text)
      expect_usage(recognition, total: transcription.usage.total_tokens)
      expect_cost(recognition, gateway_cost(transcription))
    end
  end

  describe "#generate_image" do
    it "returns a generated image, and records it with the image uploaded to Cerebro" do
      result = client.generate_image(
        message: "A plain red square on a white background.",
        parameters: { aspect_ratio: "1:1", resolution: "512", **trace_parameters }
      )

      expect(result.generated_image.mime_type).to start_with("image/")
      expect(result.generated_image.width).to be_positive
      expect(result.generated_image.height).to be_positive
      expect(result.trace_id).to eq(trace_id)

      generation = observation_named(recorded_trace("image-generation"), "image-generation")
      expect_request(generation, name: "image-generation")
      expect(generation["id"]).to eq(result.observation_id)
      expect(generation["model"]).to eq(E2eHelpers::IMAGE_MODEL)
      # The image is uploaded to Cerebro, and the output refers to it in place of its base64.
      expect(generation["output"]).to match(%r{@@@langfuseMedia:type=image/[^|]+\|id=[^|]+\|source=bytes@@@})
      expect(generation["output"]).not_to include("base64,")
      expect(generation.dig("usageDetails", "total")).to be_positive
      # The completion behind the image is not returned to the caller, so the cost is checked for presence.
      expect(generation.dig("costDetails", "total")).to be_positive
    end
  end
end
