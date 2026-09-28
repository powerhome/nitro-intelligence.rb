require "spec_helper"
require "webmock/rspec"

require "nitro_intelligence/client/handlers/responses_handler"

RSpec.describe NitroIntelligence::Client::Handlers::ResponsesHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, responses: fake_responses) }
  let(:fake_responses) { double("Responses") }

  let(:handler) { described_class.new(client: fake_openai_client) }

  before do
    fake_catalog = double("ModelCatalog", default_text_model: double("Model", name: "default-text-model"))
    allow(fake_catalog).to receive(:exists?).and_return(true)
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)
  end

  describe "#create" do
    it "sends the message as the input" do
      expect(fake_responses).to receive(:create).with(
        hash_including(input: "hello world", model: "default-text-model")
      ).and_return("fake_response")

      expect(handler.create(message: "hello world")).to eq("fake_response")
    end

    it "leaves input unset when the caller supplies none" do
      # The gateway answers a missing input with a 500 and an empty one by inventing a turn,
      # so neither may be defaulted here; the observed handler refuses the request instead.
      expect(fake_responses).to receive(:create) do |kwargs|
        expect(kwargs).not_to have_key(:input)
      end

      handler.create(parameters: {})
    end

    it "drops parameters this endpoint does not accept" do
      expect(fake_responses).to receive(:create) do |kwargs|
        expect(kwargs).not_to have_key(:messages)
        expect(kwargs).not_to have_key(:max_tokens)
      end

      handler.create(message: "hi", parameters: { messages: [{ role: "user", content: "no" }], max_tokens: 5 })
    end

    it "tags the request with nip-requested-model and no nip-modality" do
      expect(fake_responses).to receive(:create) do |kwargs|
        headers = kwargs.dig(:request_options, :extra_headers)
        expect(headers).to eq("nip-requested-model" => "default-text-model")
        expect(headers).not_to have_key("nip-modality")
      end

      handler.create(message: "hi")
    end
  end

  # Covered against a real OpenAI::Client rather than a double, for the reason the chat spec
  # gives: a stubbed `last_response` would prove only that the stub works.
  describe "the cost of a real response" do
    subject(:handler) { described_class.new(client: real_client) }

    let(:real_client) { OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example") }

    before do
      stub_request(:post, "https://gateway.example/responses").to_return(
        status: 200,
        body: {
          id: "resp_1",
          object: "response",
          created_at: 1,
          model: "default-text-model",
          status: "completed",
          parallel_tool_calls: false,
          tool_choice: "auto",
          tools: [],
          output: [
            { type: "reasoning", id: "rs_1", summary: [] },
            { type: "message", id: "msg_1", role: "assistant", status: "completed",
              content: [{ type: "output_text", text: "hi", annotations: [] }] },
          ],
          usage: { input_tokens: 11, output_tokens: 22,
                   output_tokens_details: { reasoning_tokens: 17 }, total_tokens: 33 },
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "x-litellm-response-cost" => "5.85e-06",
          "x-litellm-response-cost-input" => "1.1e-06",
          "x-litellm-response-cost-output" => "4.75e-06",
        }
      )
    end

    it "reaches the gateway's cost headers through the returned response" do
      response = handler.create(message: "hello world")

      expect(response.output_text).to eq("hi")
      expect(handler.cost_details(response)).to eq(total: 5.85e-06, input: 1.1e-06, output: 4.75e-06)
    end

    it "carries the reasoning token count the endpoint reports" do
      response = handler.create(message: "hello world")

      expect(response.usage.output_tokens_details.reasoning_tokens).to eq(17)
    end
  end
end
