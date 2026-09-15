require "spec_helper"
require "webmock/rspec"

require "nitro_intelligence/client/handlers/completion_handler"

RSpec.describe NitroIntelligence::Client::Handlers::CompletionHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, completions: fake_completions) }
  let(:fake_completions) { double("Completions") }

  let(:handler) { described_class.new(client: fake_openai_client) }

  before do
    fake_model = double("Model", name: "default-text-model")
    fake_catalog = double("ModelCatalog", default_text_model: fake_model)
    allow(fake_catalog).to receive(:exists?).and_return(true)
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)
  end

  describe "#create" do
    it "sends the message as the prompt via the OpenAI client" do
      expect(fake_completions).to receive(:create).with(
        hash_including(prompt: "hello world", model: "default-text-model")
      ).and_return("fake_response")

      response = handler.create(message: "hello world")
      expect(response).to eq("fake_response")
    end

    it "allows overriding default parameters" do
      expect(fake_completions).to receive(:create).with(
        hash_including(prompt: "Custom", model: "custom-model")
      )

      handler.create(message: "ignored", parameters: { model: "custom-model", prompt: "Custom" })
    end

    it "drops parameters the completion endpoint does not accept" do
      # `metadata` is defaulted for the spend-logs header, but unlike the chat endpoint
      # the completion endpoint has no such field, so it must not reach the request.
      expect(fake_completions).to receive(:create) do |kwargs|
        expect(kwargs).not_to have_key(:metadata)
        expect(kwargs).not_to have_key(:messages)
      end

      handler.create(message: "hi", parameters: { messages: [{ role: "user", content: "no" }] })
    end

    it "tags the request with nip-requested-model and no nip-modality (routes to the text pool)" do
      expect(fake_completions).to receive(:create) do |kwargs|
        headers = kwargs.dig(:request_options, :extra_headers)
        expect(headers).to eq("nip-requested-model" => "default-text-model")
        expect(headers).not_to have_key("nip-modality")
      end

      handler.create(message: "hi")
    end

    it "stamps nip-requested-model from the model at request time (survives a later override)" do
      parameters = {}
      handler.validate_and_resolve!(parameters, "hi")
      parameters[:model] = "changed-after-validate" # e.g. an Observed prompt-config merge

      expect(fake_completions).to receive(:create) do |kwargs|
        expect(kwargs.dig(:request_options, :extra_headers, "nip-requested-model")).to eq("changed-after-validate")
      end

      handler.perform_request(parameters:)
    end
  end

  # Covered against a real OpenAI::Client rather than a double, for the reason given in
  # the chat handler spec: a stubbed `last_response` would prove only that the stub works.
  describe "the cost of a real completion response" do
    subject(:handler) { described_class.new(client: real_client) }

    let(:real_client) { OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example") }

    before do
      stub_request(:post, "https://gateway.example/completions").to_return(
        status: 200,
        body: {
          id: "cmpl-1",
          object: "text_completion",
          created: 1,
          model: "default-text-model",
          choices: [{ index: 0, text: "hi", finish_reason: "stop" }],
          usage: { prompt_tokens: 1, completion_tokens: 2, total_tokens: 3 },
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "x-litellm-response-cost" => "5.85e-06",
          "x-litellm-response-cost-input" => "1.1e-06",
          "x-litellm-response-cost-output" => "4.75e-06",
        }
      )
    end

    it "reaches the gateway's cost headers through the returned completion" do
      completion = handler.create(message: "hello world")

      expect(completion.choices.first.text).to eq("hi")
      expect(handler.cost_details(completion)).to eq(total: 5.85e-06, input: 1.1e-06, output: 4.75e-06)
    end
  end
end
