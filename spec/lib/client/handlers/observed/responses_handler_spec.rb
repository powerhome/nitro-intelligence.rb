require "spec_helper"
require "nitro_intelligence/client/handlers/observed/responses_handler"

RSpec.describe NitroIntelligence::Client::Handlers::Observed::ResponsesHandler do
  let(:fake_openai_client) { instance_double(OpenAI::Client, responses: fake_responses) }
  let(:fake_responses) { double("Responses") }

  let(:base_handler) { NitroIntelligence::Client::Handlers::ResponsesHandler.new(client: fake_openai_client) }

  let(:fake_prompt_store) { double("PromptStore") }
  let(:fake_project) { double("Project", slug: "test-project", prompt_store: fake_prompt_store) }
  let(:fake_project_client) { double("ProjectClient", project: fake_project) }
  let(:fake_observer) { double("LangfuseObserver", project_client: fake_project_client) }
  let(:fake_generation) { double("Generation", trace_id: "abcdef0123456789abcdef0123456789") }

  let(:handler) { described_class.new(base_handler:, observer: fake_observer) }

  def response_double(reasoning_tokens: 17, headers: nil, reasoning: "because")
    usage = double("Usage", input_tokens: 11, output_tokens: 22, total_tokens: 33,
                            output_tokens_details: double("Details", reasoning_tokens:))
    items = []
    if reasoning
      items << double("ReasoningItem", type: :reasoning, summary: [],
                                       content: [double("Part", text: reasoning)])
    end
    items << double("MessageItem", type: :message, content: [])
    attrs = { model: "default-text-model", output_text: "the answer", usage:, output: items }
    attrs[:last_response] = double("LastResponse", headers:) if headers
    double("Response", **attrs)
  end

  def prompt(type:, name: "test-prompt", body: "Preamble", config: {})
    NitroIntelligence::Observability::Prompt.new(name:, type:, prompt: body, version: 1, config:)
  end

  before do
    fake_catalog = double("ModelCatalog", default_text_model: double(name: "default-text-model"))
    allow(fake_catalog).to receive(:exists?).and_return(true)
    allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_catalog)
  end

  describe "#create" do
    it "observes the request and builds trace attributes" do
      expect(fake_observer).to receive(:observe).with(
        "response",
        type: :generation,
        parameters: instance_of(Hash),
        trace_name: "test-project",
        prompt: nil,
        input: "hello"
      ).and_yield(fake_generation)
      expect(fake_responses).to receive(:create).and_return(response_double)

      response, trace_attributes = handler.create(message: "hello")

      expect(response.output_text).to eq("the answer")
      expect(trace_attributes[:output]).to eq(content: "the answer", reasoning_content: "because")
      expect(trace_attributes[:usage_details]).to eq(
        input: 11, output: 22, total: 33, reasoning_tokens: 17
      )
    end

    it "records the reasoning the endpoint returned beside the message it preceded" do
      # `output_text` is the message alone, so recording only that would drop the reasoning
      # from the trace entirely -- the endpoint returns it as a sibling item, not a field.
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)
      expect(fake_responses).to receive(:create).and_return(response_double(reasoning: "step one\nstep two"))

      _, trace_attributes = handler.create(message: "hello")

      expect(trace_attributes[:output]).to eq(content: "the answer", reasoning_content: "step one\nstep two")
    end

    it "records the message alone when the response carried no reasoning" do
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)
      expect(fake_responses).to receive(:create).and_return(response_double(reasoning: nil))

      _, trace_attributes = handler.create(message: "hello")

      expect(trace_attributes[:output]).to eq("the answer")
    end

    it "omits the reasoning count when the endpoint reports none" do
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)
      expect(fake_responses).to receive(:create).and_return(response_double(reasoning_tokens: nil))

      _, trace_attributes = handler.create(message: "hello")

      expect(trace_attributes[:usage_details]).not_to have_key(:reasoning_tokens)
    end

    it "carries the cost the gateway reported into the trace attributes" do
      allow(fake_observer).to receive(:observe).and_yield(fake_generation)
      expect(fake_responses).to receive(:create).and_return(
        response_double(headers: { "x-litellm-response-cost" => "5.85e-06",
                                   "x-litellm-response-cost-input" => "1.1e-06",
                                   "x-litellm-response-cost-output" => "4.75e-06" })
      )

      _, trace_attributes = handler.create(message: "hello")

      expect(trace_attributes[:cost_details]).to eq(total: 5.85e-06, input: 1.1e-06, output: 4.75e-06)
    end

    context "with a text prompt" do
      before { allow(fake_prompt_store).to receive(:get_prompt).and_return(prompt(type: "text", body: "Be brief. {{v}}")) }

      it "sends it as instructions rather than folding it into the input" do
        allow(fake_observer).to receive(:observe).and_yield(fake_generation)

        expect(fake_responses).to receive(:create).with(
          hash_including(instructions: "Be brief. x", input: "hello")
        ).and_return(response_double)

        handler.create(message: "hello", parameters: { prompt_name: "test-prompt", prompt_variables: { v: "x" } })
      end

      it "records the instructions alongside the input, so the trace shows the whole prompt" do
        expect(fake_observer).to receive(:observe).with(
          anything, hash_including(input: { instructions: "Be brief. x", input: "hello" })
        ).and_yield(fake_generation)
        expect(fake_responses).to receive(:create).and_return(response_double)

        handler.create(message: "hello", parameters: { prompt_name: "test-prompt", prompt_variables: { v: "x" } })
      end

      it "refuses a request the prompt alone cannot answer" do
        expect(fake_responses).not_to receive(:create)

        expect { handler.create(parameters: { prompt_name: "test-prompt" }) }
          .to raise_error(described_class::ObservedResponsesPromptError, /is a text prompt.*chat prompt in Cerebro/m)
      end
    end

    context "with a chat prompt" do
      let(:chat_prompt) do
        prompt(type: "chat", name: "chat-prompt",
               body: [{ role: "system", content: "Preamble" }, { role: "user", content: "Built in" }])
      end

      it "opens the input with the prompt's own messages, unlike #complete which refuses them" do
        allow(fake_prompt_store).to receive(:get_prompt).and_return(chat_prompt)
        allow(fake_observer).to receive(:observe).and_yield(fake_generation)

        expect(fake_responses).to receive(:create).with(
          hash_including(input: [{ role: "system", content: "Preamble" },
                                 { role: "user", content: "Built in" },
                                 { role: "user", content: "and then" }])
        ).and_return(response_double)

        handler.create(message: "and then", parameters: { prompt_name: "chat-prompt" })
      end

      it "is self-sufficient when the caller adds nothing" do
        allow(fake_prompt_store).to receive(:get_prompt).and_return(chat_prompt)
        allow(fake_observer).to receive(:observe).and_yield(fake_generation)

        expect(fake_responses).to receive(:create).with(
          hash_including(input: [{ role: "system", content: "Preamble" },
                                 { role: "user", content: "Built in" }])
        ).and_return(response_double)

        handler.create(parameters: { prompt_name: "chat-prompt" })
      end
    end

    it "refuses a request with no input and no prompt" do
      expect(fake_responses).not_to receive(:create)

      expect { handler.create(parameters: {}) }
        .to raise_error(described_class::ObservedResponsesPromptError, /carries no `input`/)
    end
  end
end
