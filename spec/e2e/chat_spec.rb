require_relative "e2e_helper"

RSpec.describe "NitroIntelligence::Client#chat", :e2e do
  include_context "with a traced request"

  let(:message) { "Reply with the single word pong and nothing else." }

  it "answers the message and records the completion with its usage and cost" do
    response = client.chat(message:, parameters: { max_tokens: 1000, **trace_parameters })

    expect(response.choices.first.message.content).to match(/pong/i)
    expect(response.last_response.headers["x-litellm-model-group"]).to eq(E2eHelpers::TEXT_MODEL)

    generation = recorded_request("chat-completion")
    expect_request(generation, name: "chat-completion")
    expect(generation["model"]).to eq(response.model)
    expect(CerebroReader.parse(generation["input"])).to eq([{ "role" => "user", "content" => message }])
    expect(CerebroReader.parse(generation["output"])).to include("role" => "assistant",
                                                                 "content" => a_string_matching(/pong/i))
    expect_accounted(generation, response)
  end

  context "without an observability project" do
    subject(:client) { NitroIntelligence::Client.new(inference_timeout: 120) }

    it "answers the message, with the gateway's cost and call ID on the response" do
      response = client.chat(message:, parameters: { max_tokens: 1000, metadata: e2e_metadata })

      expect(response.choices.first.message.content).to match(/pong/i)
      expect(response.usage.total_tokens).to be_positive
      expect(gateway_cost(response)).to be_positive
      expect(response.last_response.headers["x-litellm-call-id"]).to be_present
    end
  end

  context "with a prompt managed in Cerebro" do
    let(:prompt_name) { "nitro-intelligence.rb e2e" }
    let(:compiled_messages) do
      [
        { "role" => "system", "content" => "You answer with exactly one word." },
        { "role" => "user", "content" => message },
      ]
    end
    let!(:version) do
      cerebro.prompt_version(
        name: prompt_name,
        type: "chat",
        prompt: [
          { role: "system", content: "You answer with exactly one word." },
          { role: "user", content: "Reply with the single word {{word}} and nothing else." },
        ],
        config: { max_tokens: 1000 },
        labels: %w[production e2e]
      )
    end

    def expect_prompted_completion(response)
      expect(response.choices.first.message.content).to match(/pong/i)

      generation = recorded_request("chat-completion")
      expect_request(generation, name: "chat-completion")
      expect(generation).to include("promptName" => prompt_name, "promptVersion" => version)
      expect(CerebroReader.parse(generation["input"])).to eq(compiled_messages)
      expect_metadata(generation, prompt_name:, prompt_version: version)
      expect_accounted(generation, response)
    end

    it "compiles the production prompt, applies its config and links the completion to its version" do
      response = client.chat(parameters: { prompt_name:, prompt_variables: { word: "pong" }, **trace_parameters })

      expect_prompted_completion(response)
    end

    it "uses the prompt at the label asked for" do
      response = client.chat(
        parameters: { prompt_name:, prompt_label: "e2e", prompt_variables: { word: "pong" }, **trace_parameters }
      )

      expect_prompted_completion(response)
    end

    it "uses the prompt at the version asked for" do
      response = client.chat(
        parameters: { prompt_name:, prompt_version: version, prompt_variables: { word: "pong" }, **trace_parameters }
      )

      expect_prompted_completion(response)
    end

    it "falls back to another prompt when the one asked for does not exist" do
      response = client.chat(
        parameters: {
          prompt_name: "nitro-intelligence.rb e2e: no such prompt", prompt_fallback_name: prompt_name,
          prompt_variables: { word: "pong" }, **trace_parameters
        }
      )

      expect_prompted_completion(response)
    end

    it "reads the prompt with its version, labels and config" do
      prompt = client.prompt(prompt_name, label: "e2e")

      expect(prompt).to have_attributes(name: prompt_name, type: "chat", version:, config: { max_tokens: 1000 })
      expect(prompt.labels).to include("production", "e2e")
      expect(prompt.compile(word: "pong").map(&:deep_stringify_keys)).to eq(compiled_messages)
    end
  end

  context "with a project that masks content" do
    it "records the completion's usage and cost but none of its content" do
      response = masked_client.chat(message:, parameters: { max_tokens: 1000, **trace_parameters })

      expect(response.choices.first.message.content).to match(/pong/i)

      generation = recorded_request("chat-completion")
      expect_request(generation, name: "chat-completion")
      expect_masked(generation)
      expect_accounted(generation, response)
    end
  end

  context "when the gateway refuses the request" do
    it "raises, and records the failure" do
      error = nil
      expect do
        client.chat(message:, parameters: { model: E2eHelpers::UNKNOWN_MODEL, **trace_parameters })
      rescue OpenAI::Errors::APIStatusError => e
        error = e
        raise
      end.to raise_error(OpenAI::Errors::APIStatusError)

      generation = recorded_request("chat-completion")
      expect(generation).to include("traceName" => trace_name, "model" => E2eHelpers::UNKNOWN_MODEL,
                                    "level" => "ERROR", "statusMessage" => a_string_starting_with("OpenAI::Errors::"))
      expect(CerebroReader.parse(generation["input"])).to eq([{ "role" => "user", "content" => message }])
      # The gateway sends its call ID on the errors it raises once it has taken the request on, and the
      # failure records whichever it sent.
      expect(generation.fetch("metadata")["litellm_call_id"]).to eq(error.headers["x-litellm-call-id"])
    end
  end
end
