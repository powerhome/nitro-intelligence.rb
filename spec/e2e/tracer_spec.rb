require_relative "e2e_helper"

# A feature whose work is more than one model call, traced as an application traces it: its own
# steps and the gem's requests nested under one trace, which is then scored.
RSpec.describe NitroIntelligence::Tracer, :e2e do
  subject(:tracer) { described_class.new(observability_project_slug: E2eHelpers::OBSERVABILITY_PROJECT_SLUG) }

  let(:client) do
    NitroIntelligence::Client.new(observability_project_slug: E2eHelpers::OBSERVABILITY_PROJECT_SLUG,
                                  inference_timeout: 120)
  end
  let(:reporter) { NitroIntelligence::Reporter.new(observability_project_slug: E2eHelpers::OBSERVABILITY_PROJECT_SLUG) }
  let(:trace_seed) { new_trace_seed }
  let(:trace_id) { NitroIntelligence::Trace.create_id(seed: trace_seed) }
  let(:trace_name) { "nitro-intelligence.rb e2e: answer a question" }
  let(:user_id) { "nitro-intelligence.rb-e2e" }
  let(:question) { "How do I book vacation days?" }
  let(:passages) { ["To request time off, submit a PTO request in the HR portal for your manager to approve."] }

  # A retrieval step of the application's own, then a model call that answers from what it found.
  def answer_question
    tracer.trace(trace_name, input: { question: }, user_id:, tags: ["e2e"], metadata: e2e_metadata,
                             trace_seed:) do |root|
      found = root.observe("search handbook", as_type: :retriever, input: { question: }) do |step|
        passages.tap { step.output = _1 }
      end
      # The request's own trace name and user are the trace's, so these are not recorded.
      response = client.chat(
        message: "Using only this passage, answer in one sentence: #{question}\n\n#{found.join("\n")}",
        parameters: { max_tokens: 4000, trace_name: "ignored", user_id: "ignored" }
      )
      root.output = { answer: response.choices.first.message.content }
      [root, response]
    end
  end

  it "records the application's steps and the gem's requests in one trace, and scores it" do
    root, response = answer_question

    expect(response.choices.first.message.content).to match(/PTO|HR portal/i)

    reporter.score(trace_id:, name: "e2e-answered", value: 1, comment: "nitro-intelligence.rb e2e")
    reporter.score(trace_id:, observation_id: root.id, name: "e2e-grounded", value: true, data_type: :boolean)
    flush_observations

    observations = cerebro.observations(trace_id) do |recorded|
      recorded.size == 3 && recorded.all? { _1["endTime"] } && recorded.any? { _1.dig("costDetails", "total") }
    end
    expect(observations).to all(include("traceId" => trace_id, "userId" => user_id, "tags" => ["e2e"],
                                        "environment" => NitroIntelligence.environment))

    span = observation_named(observations, trace_name)
    expect(span).to include("id" => root.id, "type" => "SPAN", "parentObservationId" => nil, "traceName" => trace_name)
    expect(CerebroReader.parse(span["input"])).to eq("question" => question)
    expect(CerebroReader.parse(span["output"])).to eq("answer" => response.choices.first.message.content)
    expect_metadata(span, e2e_metadata)

    retrieval = observation_named(observations, "search handbook")
    expect(retrieval).to include("type" => "RETRIEVER", "parentObservationId" => root.id)
    expect(CerebroReader.parse(retrieval["output"])).to eq(passages)

    generation = observation_named(observations, "chat-completion")
    expect(generation).to include("type" => "GENERATION", "parentObservationId" => root.id)
    expect_usage(generation, total: response.usage.total_tokens)
    expect_cost(generation, gateway_cost(response))

    scores = cerebro.scores(trace_id) { _1.size == 2 }
    expect(scores.find { _1["name"] == "e2e-answered" }).to include(
      "traceId" => trace_id, "observationId" => nil, "dataType" => "NUMERIC", "value" => 1,
      "comment" => "nitro-intelligence.rb e2e", "environment" => NitroIntelligence.environment
    )
    expect(scores.find { _1["name"] == "e2e-grounded" }).to include(
      "traceId" => trace_id, "observationId" => root.id, "dataType" => "BOOLEAN", "value" => 1
    )
  end
end
