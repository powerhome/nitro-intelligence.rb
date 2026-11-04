require "spec_helper"
require "webmock/rspec"

require "nitro_intelligence/client/handlers/decision_handler"
require "nitro_intelligence/client/handlers/observed/decision_handler"
require "nitro_intelligence/client/observers/langfuse_observer"
require "nitro_intelligence/observability/project"

RSpec.describe NitroIntelligence::Client::Handlers::Observed::DecisionHandler do
  let(:client) { OpenAI::Client.new(api_key: "test", base_url: "https://gateway.example", max_retries: 0) }
  let(:base_handler) { NitroIntelligence::Client::Handlers::DecisionHandler.new(client:) }

  let(:fake_project) { double("Project", slug: "test-project", mask_content?: false) }
  let(:fake_project_client) { double("ProjectClient", project: fake_project) }
  let(:fake_observer) { double("LangfuseObserver", project_client: fake_project_client) }
  let(:fake_generation) { instance_double(Langfuse::Generation, trace_id: "trace-123", id: "obs-1") }

  let(:handler) { described_class.new(base_handler:, observer: fake_observer) }

  let(:model_config) do
    {
      default_decision_model: "typesafe/jev-1.14",
      models: [{ name: "typesafe/jev-1.14", type: "decision" }, { name: "other/decider", type: "decision" }],
    }
  end

  let(:state) { "I was charged twice. Please help." }
  let(:questions) { { billing: { type: "noul", instructions: "Is this message about billing?" } } }

  let(:response_body) do
    {
      model: "typesafe/jev-1.14",
      answers: { billing: { type: "noul", noul: 0.98 } },
      usage: { input_tokens: 120, output_tokens: 3 },
    }
  end
  let(:response_headers) { { "Content-Type" => "application/json", "x-litellm-response-cost" => "1.764e-05" } }

  let!(:systemone) do
    stub_request(:post, "https://gateway.example/v1/systemone")
      .to_return(status: 200, body: response_body.to_json, headers: response_headers)
  end

  before do
    allow(NitroIntelligence).to receive(:model_catalog).and_return(NitroIntelligence::ModelCatalog.new(model_config))
  end

  describe "#create" do
    it "observes the request as a generation with the state and questions as input" do
      expect(fake_observer).to receive(:observe).with(
        "decision",
        hash_including(type: :generation, trace_name: "test-project", input: { state:, questions: })
      ).and_yield(fake_generation)

      handler.create(state:, questions:)
    end

    it "sends the observation's trace ID to the gateway" do
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)

      handler.create(state:, questions:)

      expect(systemone.with(headers: { "x-litellm-trace-id" => "trace-123" })).to have_been_requested
    end

    it "records the answers, model, usage and the gateway's cost" do
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)

      decision, trace_attributes = handler.create(state:, questions:)

      expect(decision.answers[:billing].noul).to eq(0.98)
      expect(trace_attributes).to eq(
        model: "typesafe/jev-1.14",
        output: { billing: { type: "noul", noul: 0.98 } },
        usage_details: { prompt_tokens: 120, completion_tokens: 3, total_tokens: 123 },
        cost_details: { total: 1.764e-05 }
      )
    end

    it "records a copy of the answers, so truncating the recording leaves the caller's alone" do
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)

      decision, trace_attributes = handler.create(state:, questions:)
      trace_attributes[:output][:billing][:noul] = "[Truncated...]"

      expect(decision.raw_answers[:billing][:noul]).to eq(0.98)
    end

    it "leaves the cost unset when the gateway did not price the request" do
      stub_request(:post, "https://gateway.example/v1/systemone").to_return(status: 200, body: response_body.to_json, headers: { "Content-Type" => "application/json" })
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)

      _, trace_attributes = handler.create(state:, questions:)

      expect(trace_attributes[:cost_details]).to be_nil
    end

    it "leaves usage unset when the response carries none" do
      stub_request(:post, "https://gateway.example/v1/systemone").to_return(status: 200, body: response_body.except(:usage).to_json, headers: response_headers)
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)

      _, trace_attributes = handler.create(state:, questions:)

      expect(trace_attributes[:usage_details]).to be_nil
    end

    it "asks the gateway to redact the request from its logs when the project masks content" do
      allow(fake_project).to receive(:mask_content?).and_return(true)
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)

      handler.create(state:, questions:)

      expect(systemone.with(headers: { "x-litellm-enable-message-redaction" => "true" })).to have_been_requested
    end

    context "with a project that masks content, observed for real" do
      let(:project) do
        NitroIntelligence::Observability::Project.new(slug: "masked", id: "p", public_key: "pk", secret_key: "sk", mask_content: true)
      end
      let(:recorded) { [] }
      let(:generation) do
        double("Generation", trace_id: "trace-123", id: "obs-1").tap do |generation|
          allow(generation).to receive(:update)
          %i[model= model_parameters= usage_details= cost_details= input= output=].each do |setter|
            allow(generation).to receive(setter) { |value| recorded << [setter, value] }
          end
          allow(generation).to receive(:update_trace) { |attributes| recorded << [:update_trace, attributes] }
        end
      end
      let(:observability_client) { double("ObservabilityClient") }
      let(:project_client) { double("ProjectClient", project:, observability_client:) }
      let(:handler) do
        described_class.new(
          base_handler:, observer: NitroIntelligence::Client::Observers::LangfuseObserver.new(project_client:)
        )
      end

      before do
        allow(Langfuse).to receive(:propagate_attributes).and_yield
        allow(observability_client).to receive(:observe).and_yield(generation)
      end

      it "records neither the state, the questions nor the answers" do
        decision = handler.create(state:, questions:)

        expect(decision.answers[:billing].noul).to eq(0.98)
        recorded_text = recorded.to_s
        expect(recorded_text).not_to include("charged twice", "billing", "0.98")
        expect(recorded).to include([:input=, "[masked]"], [:output=, "[masked]"])
        expect(recorded).to include([:cost_details=, { total: 1.764e-05 }])
      end
    end

    it "leaves the gateway's logs alone when the project does not mask content" do
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)

      handler.create(state:, questions:)

      expect(systemone.with { |request| !request.headers.key?("X-Litellm-Enable-Message-Redaction") })
        .to have_been_requested
    end

    it "uses the supplied trace_name instead of the project slug" do
      expect(fake_observer).to receive(:observe)
        .with("decision", hash_including(trace_name: "triage")).and_yield(fake_generation)

      handler.create(state:, questions:, parameters: { trace_name: "triage" })
    end

    it "validates the model before observing anything" do
      expect(fake_observer).not_to receive(:observe)

      expect { handler.create(state:, questions:, parameters: { model: "ghost" }) }
        .to raise_error(ArgumentError, /Unsupported model: 'ghost'/)
    end
  end
end
