require "spec_helper"
require "webmock/rspec"

require "nitro_intelligence/client/handlers/decision_handler"

RSpec.describe NitroIntelligence::Client::Handlers::DecisionHandler do
  subject(:handler) { described_class.new(client:) }

  let(:client) { OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example", max_retries: 0) }

  let(:model_config) do
    {
      default_decision_model: "typesafe/jev-1.14",
      models: [
        { name: "typesafe/jev-1.14", type: "decision" },
        { name: "other/decider", type: "decision" },
        { name: "Qwen/Qwen3.6-35B-A3B", type: "text" },
      ],
    }
  end

  let(:state) { { subject: "Duplicate charge", message: "I was charged twice. Please help." } }
  let(:questions) do
    {
      billing: { type: "noul", instructions: "Is this message about billing?" },
      team: {
        type: "choice",
        instructions: "Which team should handle this message?",
        criteria: { payments: "Charges and refunds", other: "Anything else" },
      },
      urgency: {
        type: "score",
        instructions: "How urgent is this message?",
        criteria: ["Can wait", "Needs attention today"],
      },
    }
  end

  let(:response_body) do
    {
      model: "typesafe/jev-1.14",
      answers: {
        billing: { type: "noul", noul: 0.98 },
        team: { type: "choice", choice: "payments", confidence: 0.91, probabilities: { payments: 0.95, other: 0.05 } },
        urgency: {
          type: "score", score: 0.8, confidence: 0.55,
          legend: { "0" => "Can wait", "1" => "Needs attention today" },
          probabilities: { "0" => 0.2, "1" => 0.8 }
        },
      },
      usage: { input_tokens: 120, output_tokens: 3 },
    }
  end

  let(:response_headers) do
    {
      "Content-Type" => "application/json",
      "x-litellm-response-cost" => "1.764e-05",
      "x-litellm-call-id" => "call-123",
    }
  end

  let!(:systemone) do
    stub_request(:post, "https://gateway.example/systemone")
      .to_return(status: 200, body: response_body.to_json, headers: response_headers)
  end

  before do
    allow(NitroIntelligence).to receive(:model_catalog).and_return(NitroIntelligence::ModelCatalog.new(model_config))
  end

  describe "#create" do
    it "posts the model, state and questions to System One" do
      handler.create(state:, questions:)

      expect(systemone.with(body: { model: "typesafe/jev-1.14", state:, questions: })).to have_been_requested
    end

    it "sends the requested model and the caller's metadata as gateway headers" do
      handler.create(state:, questions:, parameters: { metadata: { feature: "triage" } })

      expect(
        systemone.with(headers: {
                         "nip-requested-model" => "typesafe/jev-1.14",
                         "x-litellm-spend-logs-metadata" => { feature: "triage" }.to_json,
                       })
      ).to have_been_requested
    end

    it "keeps metadata and observability parameters out of the body" do
      handler.create(state:, questions:, parameters: { metadata: { a: 1 }, trace_name: "t", user_id: "u" })

      expect(systemone.with { |request| JSON.parse(request.body).keys == %w[model state questions] })
        .to have_been_requested
    end

    it "returns typed answers keyed by question name" do
      decision = handler.create(state:, questions:)

      expect(decision).to be_a(NitroIntelligence::Decision)
      expect(decision.model).to eq("typesafe/jev-1.14")
      expect(decision.answers[:billing]).to eq(NitroIntelligence::Decision::NoulAnswer.new(noul: 0.98))
      expect(decision.answers["team"]).to eq(
        NitroIntelligence::Decision::ChoiceAnswer.new(
          choice: "payments", confidence: 0.91, probabilities: { "payments" => 0.95, "other" => 0.05 }
        )
      )
      expect(decision.answers[:urgency]).to eq(
        NitroIntelligence::Decision::ScoreAnswer.new(
          score: 0.8, confidence: 0.55,
          probabilities: { 0 => 0.2, 1 => 0.8 },
          legend: { 0 => "Can wait", 1 => "Needs attention today" }
        )
      )
      expect(decision.usage).to eq(input_tokens: 120, output_tokens: 3)
    end

    it "returns an answer of a type it does not model as the hash it arrived as" do
      response_body[:answers] = { spot: { type: "box", box: { top: 0.2 }, confidence: nil } }
      stub_request(:post, "https://gateway.example/systemone").to_return(status: 200, body: response_body.to_json, headers: response_headers)

      decision = handler.create(state:, questions:)

      expect(decision.answers[:spot]).to include(type: "box", box: { top: 0.2 })
      expect(decision.answers["spot"]["box"]["top"]).to eq(0.2)
    end

    it "reaches the gateway's cost headers through the decision" do
      decision = handler.create(state:, questions:)

      expect(decision.last_response.headers["x-litellm-call-id"]).to eq("call-123")
      expect(handler.cost_details(decision)).to eq(total: 1.764e-05)
    end

    it "raises the client's errors for a rejected request" do
      stub_request(:post, "https://gateway.example/systemone").to_return(
        status: 403,
        body: { error: { message: "no access" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      expect { handler.create(state:, questions:) }.to raise_error(OpenAI::Errors::PermissionDeniedError)
    end

    it "uses the explicitly provided model" do
      handler.create(state:, questions:, parameters: { model: "other/decider" })

      expect(systemone.with { |request| JSON.parse(request.body)["model"] == "other/decider" }).to have_been_requested
    end

    it "raises when the requested model is not in the catalog" do
      expect { handler.create(state:, questions:, parameters: { model: "ghost" }) }
        .to raise_error(ArgumentError, /Unsupported model: 'ghost'/)
      expect(systemone).not_to have_been_requested
    end

    it "keeps a score level that is not a number as it came" do
      response_body[:answers] = {
        urgency: { type: "score", score: 0.5, confidence: 0.1, legend: { "0" => "Low", "x" => "?" },
                   probabilities: { "0" => 0.5, "x" => 0.5 } },
      }
      stub_request(:post, "https://gateway.example/systemone")
        .to_return(status: 200, body: response_body.to_json, headers: response_headers)

      expect(handler.create(state:, questions:).answers[:urgency].legend).to eq(0 => "Low", "x" => "?")
    end

    it "raises when the requested model is not a decision model" do
      expect { handler.create(state:, questions:, parameters: { model: "Qwen/Qwen3.6-35B-A3B" }) }
        .to raise_error(ArgumentError, "Model 'Qwen/Qwen3.6-35B-A3B' is not a decision model")
      expect(systemone).not_to have_been_requested
    end

    it "raises when no model is provided and the catalog has no default" do
      allow(NitroIntelligence).to receive(:model_catalog)
        .and_return(NitroIntelligence::ModelCatalog.new(model_config.except(:default_decision_model)))

      expect { handler.create(state:, questions:) }.to raise_error(ArgumentError, /Unsupported model: ''/)
    end
  end
end
