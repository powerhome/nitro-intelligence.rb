require_relative "e2e_helper"

RSpec.describe "NitroIntelligence::Client#decide", :e2e do
  include_context "with a traced request"

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

    generation = recorded_request("decision")
    expect_request(generation, name: "decision")
    expect(generation["model"]).to eq(decision.model)
    expect(CerebroReader.parse(generation["input"])).to include("state" => state)
    expect(CerebroReader.parse(generation["output"]).keys).to contain_exactly("billing", "weather")
    expect_usage(generation, total: decision.usage[:input_tokens] + decision.usage[:output_tokens])
    expect_cost(generation, gateway_cost(decision))
  end
end
