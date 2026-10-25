require "spec_helper"
require "nitro_intelligence/assistants"
require "webmock/rspec"

RSpec.describe NitroIntelligence do
  describe ".assistants" do
    let(:base_url) { "https://assistants.example.com" }
    let(:api_key) { "test-api-key" }

    before do
      NitroIntelligence.configuration.assistants_config = {
        "base_url" => base_url,
        "api_key" => api_key,
      }
    end

    after do
      NitroIntelligence.configuration.assistants_config = {}
    end

    it "returns an instance of Assistants" do
      expect(described_class.assistants).to be_a(NitroIntelligence::Assistants)
    end

    it "configures Assistants with assistants_config" do
      assistants = described_class.assistants

      expect(assistants.base_url).to eq(base_url)
    end

    it "returns a new instance on each call" do
      first_instance = described_class.assistants
      second_instance = described_class.assistants

      expect(first_instance).not_to be(second_instance)
    end

    context "with custom user_id in config" do
      before do
        NitroIntelligence.configuration.assistants_config = {
          "base_url" => base_url,
          "api_key" => api_key,
          "user_id" => "custom-user",
        }
      end

      it "uses the configured user_id" do
        expect(described_class.assistants.user_id).to eq("custom-user")
      end
    end

    context "without user_id in config" do
      it "uses the default user_id" do
        expect(described_class.assistants.user_id).to eq("default-user")
      end
    end

    context "without base_url in config" do
      before do
        NitroIntelligence.configuration.assistants_config = { "api_key" => api_key }
      end

      it "uses the shared Assistants deployment" do
        expect(described_class.assistants.base_url).to eq(NitroIntelligence::Assistants::DEFAULT_BASE_URL)
      end
    end
  end
end

RSpec.describe NitroIntelligence::Assistants do
  let(:base_url) { "https://assistants.example.com" }
  let(:api_key) { "test-api-key" }
  let(:user_id) { "user-123" }
  let(:assistants) { described_class.new(base_url:, api_key:, user_id:) }

  describe "#initialize" do
    context "with valid parameters" do
      it "creates an instance with the provided base_url" do
        expect(assistants.base_url).to eq(base_url)
      end

      it "creates an instance with the provided user_id" do
        expect(assistants.user_id).to eq(user_id)
      end
    end

    context "with default user_id" do
      let(:assistants_with_default_user) { described_class.new(base_url:, api_key:) }

      it "defaults user_id to 'default-user'" do
        expect(assistants_with_default_user.user_id).to eq("default-user")
      end
    end

    context "with missing base_url" do
      it "defaults to the shared Assistants deployment when base_url is absent" do
        expect(described_class.new(api_key:, user_id:).base_url).to eq(described_class::DEFAULT_BASE_URL)
      end

      it "defaults when base_url is empty" do
        expect(described_class.new(base_url: "", api_key:, user_id:).base_url)
          .to eq(described_class::DEFAULT_BASE_URL)
      end
    end

    context "with missing api_key" do
      it "raises ConfigurationError when api_key is nil" do
        expect do
          described_class.new(base_url:, api_key: nil, user_id:)
        end.to raise_error(NitroIntelligence::Assistants::ConfigurationError, "api_key is required")
      end

      it "raises ConfigurationError when api_key is empty" do
        expect do
          described_class.new(base_url:, api_key: "", user_id:)
        end.to raise_error(NitroIntelligence::Assistants::ConfigurationError, "api_key is required")
      end
    end

    context "with missing user_id" do
      it "raises ConfigurationError when user_id is nil" do
        expect do
          described_class.new(base_url:, api_key:, user_id: nil)
        end.to raise_error(NitroIntelligence::Assistants::ConfigurationError, "user_id is required")
      end

      it "raises ConfigurationError when user_id is empty" do
        expect do
          described_class.new(base_url:, api_key:, user_id: "")
        end.to raise_error(NitroIntelligence::Assistants::ConfigurationError, "user_id is required")
      end
    end
  end

  describe "#await_run" do
    include_context "with an Assistants thread"

    let(:assistant_id) { "assistant-789" }
    let(:context) { { key: "value" } }
    let(:graph_id) { "confirmation-agent" }
    let(:assistant_url) { "#{base_url}/assistants/#{assistant_id}" }
    let(:thread_init_url) { "#{base_url}/threads" }
    let(:thread_state_url) { state_url }

    context "when messages is nil" do
      it "raises RunError" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages: nil, context:)
        end.to raise_error(NitroIntelligence::Assistants::RunError, "messages cannot be empty")
      end

      it "does not attempt to initialize the thread" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages: nil, context:)
        end.to raise_error(NitroIntelligence::Assistants::RunError)

        expect(WebMock).not_to have_requested(:post, thread_init_url)
      end
    end

    context "when messages is empty" do
      it "raises RunError" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages: [], context:)
        end.to raise_error(NitroIntelligence::Assistants::RunError, "messages cannot be empty")
      end

      it "does not attempt to initialize the thread" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages: [], context:)
        end.to raise_error(NitroIntelligence::Assistants::RunError)

        expect(WebMock).not_to have_requested(:post, thread_init_url)
      end
    end

    let(:messages) do
      [
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Hi there!" },
        { role: "user", content: "How are you?" },
      ]
    end

    let(:run_response_body) do
      {
        "messages" => [
          { "role" => "assistant", "content" => "I'm doing well, thank you!" },
        ],
      }
    end

    let(:thread_init_request_body) do
      {
        threadId: thread_id.to_s,
        ifExists: "raise",
        metadata: { graph_id: },
        user_id:,
      }
    end

    let(:thread_state_request_body) do
      {
        values: { messages: messages[0..-2] },
      }
    end

    let(:run_request_body) do
      {
        assistant_id:,
        context:,
        input: {
          messages: [messages.last],
        },
      }
    end

    before do
      stub_json(:get, assistant_url, { assistant_id:, name: graph_id, graph_id: })

      stub_json(:post, thread_init_url, {}, request_body: thread_init_request_body)

      stub_json(:post, thread_state_url, {}, request_body: thread_state_request_body)

      stub_json(:post, run_url, run_response_body, request_body: run_request_body)
    end

    it "creates the thread" do
      assistants.await_run(thread_id:, assistant_id:, messages:, context:)

      expect(WebMock).to have_requested(:post, thread_init_url)
        .with(body: thread_init_request_body.to_json)
    end

    it "seeds the new thread with every message except the last" do
      assistants.await_run(thread_id:, assistant_id:, messages:, context:)

      expect(WebMock).to have_requested(:post, thread_state_url)
        .with(body: thread_state_request_body.to_json)
    end

    it "tags the thread with the assistant's graph, not the assistant's id" do
      assistants.await_run(thread_id:, assistant_id:, messages:, context:)

      expect(WebMock).to have_requested(:post, thread_init_url)
        .with(body: hash_including(metadata: { graph_id: }))
    end

    it "looks the graph up on the assistant" do
      assistants.await_run(thread_id:, assistant_id:, messages:, context:)

      expect(WebMock).to have_requested(:get, assistant_url)
    end

    it "looks the graph up only once per assistant" do
      assistants.await_run(thread_id:, assistant_id:, messages:, context:)
      assistants.await_run(thread_id:, assistant_id:, messages:, context:)

      expect(WebMock).to have_requested(:get, assistant_url).once
    end

    context "when the assistant cannot be fetched" do
      before do
        stub_json(:get, assistant_url, { error: "not_found" }, status: 404)
      end

      it "raises ThreadInitializationError" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadInitializationError, '{"error":"not_found"}')
      end

      it "does not attempt to create the thread" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadInitializationError)

        expect(WebMock).not_to have_requested(:post, thread_init_url)
      end
    end

    context "when the assistant has no graph_id" do
      before do
        stub_json(:get, assistant_url, { assistant_id: })
      end

      it "raises ThreadInitializationError" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadInitializationError,
          "Assistant #{assistant_id} has no graph_id"
        )
      end
    end

    it "asks Assistants to raise when the thread already exists" do
      assistants.await_run(thread_id:, assistant_id:, messages:, context:)

      expect(WebMock).to have_requested(:post, thread_init_url)
        .with(body: hash_including(ifExists: "raise"))
    end

    it "triggers a run with the last message" do
      assistants.await_run(thread_id:, assistant_id:, messages:, context:)

      expect(WebMock).to have_requested(:post, run_url)
        .with(body: run_request_body.to_json)
    end

    context "when the thread already exists" do
      before do
        stub_json(:post, thread_init_url, { error: "Thread #{thread_id} already exists" }, status: 409)
      end

      it "does not raise ThreadInitializationError" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.not_to raise_error
      end

      it "does not seed the thread state again" do
        assistants.await_run(thread_id:, assistant_id:, messages:, context:)

        expect(WebMock).not_to have_requested(:post, thread_state_url)
      end

      it "still triggers the run" do
        assistants.await_run(thread_id:, assistant_id:, messages:, context:)

        expect(WebMock).to have_requested(:post, run_url)
          .with(body: run_request_body.to_json)
      end

      it "returns the content of the last message from the run response" do
        result = assistants.await_run(thread_id:, assistant_id:, messages:, context:)

        expect(result).to eq("I'm doing well, thank you!")
      end
    end

    it "returns the content of the last message from the run response" do
      result = assistants.await_run(thread_id:, assistant_id:, messages:, context:)

      expect(result).to eq("I'm doing well, thank you!")
    end

    context "when context is not provided" do
      let(:run_request_body_without_context) do
        {
          assistant_id:,
          context: {},
          input: {
            messages: [messages.last],
          },
        }
      end

      before do
        stub_json(:post, run_url, run_response_body, request_body: run_request_body_without_context)
      end

      it "uses an empty hash as default context" do
        assistants.await_run(thread_id:, assistant_id:, messages:)

        expect(WebMock).to have_requested(:post, run_url)
          .with(body: run_request_body_without_context.to_json)
      end
    end

    context "when there is only one message" do
      let(:single_message) { [{ role: "user", content: "Hello" }] }

      let(:single_message_thread_init_body) do
        {
          threadId: thread_id.to_s,
          ifExists: "raise",
          metadata: { graph_id: },
          user_id:,
        }
      end

      let(:single_message_run_body) do
        {
          assistant_id:,
          context:,
          input: {
            messages: [single_message.last],
          },
        }
      end

      before do
        stub_json(:post, thread_init_url, {}, request_body: single_message_thread_init_body)

        stub_json(:post, run_url, run_response_body, request_body: single_message_run_body)
      end

      it "creates the thread" do
        assistants.await_run(thread_id:, assistant_id:, messages: single_message, context:)

        expect(WebMock).to have_requested(:post, thread_init_url)
          .with(body: single_message_thread_init_body.to_json)
      end

      it "does not seed the thread state, as there is nothing to seed it with" do
        assistants.await_run(thread_id:, assistant_id:, messages: single_message, context:)

        expect(WebMock).not_to have_requested(:post, thread_state_url)
      end

      it "triggers run with the single message" do
        assistants.await_run(thread_id:, assistant_id:, messages: single_message, context:)

        expect(WebMock).to have_requested(:post, run_url)
          .with(body: single_message_run_body.to_json)
      end
    end

    context "when thread initialization fails" do
      before do
        stub_json(:post, thread_init_url, { error: "Internal Server Error" }, status: 500)
      end

      it "raises ThreadInitializationError" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadInitializationError, '{"error":"Internal Server Error"}')
      end

      it "does not attempt to seed the thread state or trigger the run" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadInitializationError)

        expect(WebMock).not_to have_requested(:post, thread_state_url)
        expect(WebMock).not_to have_requested(:post, run_url)
      end
    end

    context "when seeding the thread state fails" do
      before do
        stub_json(:post, thread_state_url, { error: "Internal Server Error" }, status: 500)

        stub_request(:delete, thread_url).to_return(status: 200, body: {}.to_json)
      end

      it "raises ThreadInitializationError" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadInitializationError, '{"error":"Internal Server Error"}')
      end

      it "does not attempt to trigger the run" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadInitializationError)

        expect(WebMock).not_to have_requested(:post, run_url)
      end

      it "discards the thread it just created, so a retry can seed it again" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadInitializationError)

        expect(WebMock).to have_requested(:delete, thread_url)
      end

      context "when discarding the thread also fails" do
        before do
          stub_request(:delete, thread_url).to_return(status: 500, body: {}.to_json)
        end

        it "still raises the seeding failure" do
          expect do
            assistants.await_run(thread_id:, assistant_id:, messages:, context:)
          end.to raise_error(
            NitroIntelligence::Assistants::ThreadInitializationError,
            '{"error":"Internal Server Error"}'
          )
        end
      end

      context "when the connection drops while seeding" do
        before do
          stub_request(:post, thread_state_url).to_timeout
        end

        it "discards the thread and lets the connection error surface" do
          expect do
            assistants.await_run(thread_id:, assistant_id:, messages:, context:)
          end.to raise_error(Net::OpenTimeout)

          expect(WebMock).to have_requested(:delete, thread_url)
        end
      end
    end

    context "when seeding the thread state succeeds" do
      it "leaves the thread in place" do
        assistants.await_run(thread_id:, assistant_id:, messages:, context:)

        expect(WebMock).not_to have_requested(:delete, thread_url)
      end
    end

    context "when run trigger fails" do
      before do
        stub_json(:post, run_url, { error: "Internal Server Error" }, status: 500)
      end

      it "raises RunError" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(NitroIntelligence::Assistants::RunError, '{"error":"Internal Server Error"}')
      end
    end

    context "when the run fails inside a successful response" do
      let(:run_response_body) do
        {
          "__error__" => {
            "error" => "Error",
            "message" => "KeyError: missing variables {'first_name'}",
          },
        }
      end

      it "raises RunError with the reported failure" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(
          NitroIntelligence::Assistants::RunError,
          "Error: KeyError: missing variables {'first_name'}"
        )
      end
    end

    context "when the run did not finish" do
      let(:run_response_body) do
        {
          "__error__" => {
            "error" => "IncompleteRun",
            "message" => "Wait ended before the run completed (status: running)",
          },
        }
      end

      it "raises rather than reporting the run as having no answer" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(
          NitroIntelligence::Assistants::RunError,
          "IncompleteRun: Wait ended before the run completed (status: running)"
        )
      end
    end

    context "when a successful run reports no failure" do
      it "does not raise" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.not_to raise_error
      end
    end

    context "when run returns multiple messages" do
      let(:multi_message_run_response_body) do
        {
          "messages" => [
            { "role" => "assistant", "content" => "First response" },
            { "role" => "assistant", "content" => "Second response" },
            { "role" => "assistant", "content" => "Final response" },
          ],
        }
      end

      before do
        stub_json(:post, run_url, multi_message_run_response_body, request_body: run_request_body)
      end

      it "returns the content of the last message" do
        result = assistants.await_run(thread_id:, assistant_id:, messages:, context:)

        expect(result).to eq("Final response")
      end
    end

    context "when run response messages are nil" do
      let(:run_response_body) do
        {
          "messages" => nil,
        }
      end

      it "returns nil" do
        result = assistants.await_run(thread_id:, assistant_id:, messages:, context:)

        expect(result).to be_nil
      end
    end

    context "with various HTTP error status codes for thread initialization" do
      [400, 401, 403, 404, 422, 502, 503].each do |status_code|
        context "when thread initialization returns #{status_code}" do
          before do
            stub_json(:post, thread_init_url, {}, status: status_code)
          end

          it "raises ThreadInitializationError" do
            expect do
              assistants.await_run(thread_id:, assistant_id:, messages:, context:)
            end.to raise_error(NitroIntelligence::Assistants::ThreadInitializationError)
          end
        end
      end
    end

    context "with various HTTP error status codes for run trigger" do
      [400, 401, 403, 404, 422, 502, 503].each do |status_code|
        context "when run trigger returns #{status_code}" do
          before do
            stub_json(:post, run_url, {}, status: status_code)
          end

          it "raises RunError" do
            expect do
              assistants.await_run(thread_id:, assistant_id:, messages:, context:)
            end.to raise_error(NitroIntelligence::Assistants::RunError)
          end
        end
      end
    end
  end

  describe "#tool_calls_under_review" do
    include_context "with an Assistants thread"

    let(:messages) do
      [
        {
          "type" => "human",
          "id" => "communication-1",
          "content" => "Please look up my account",
        },
        {
          "type" => "ai",
          "id" => "ai-message-1",
          "content" => "",
          "tool_calls" => [
            { "id" => "tool_call_id_1", "name" => "lookup_account", "args" => {} },
            { "id" => "tool_call_id_2", "name" => "send_invoice", "args" => { "amount" => 100 } },
          ],
        },
      ]
    end
    let(:interrupts) do
      [
        {
          "value" => {
            "action_requests" => [
              { "name" => "send_invoice", "args" => { "amount" => 100 } },
            ],
            "review_configs" => [
              { "action_name" => "send_invoice", "allowed_decisions" => %w[approve reject] },
            ],
          },
        },
      ]
    end

    before do
      stub_json(:get, state_url, { "values" => { "messages" => messages }, "interrupts" => interrupts })
    end

    it "reports only the tool calls the interrupt is holding, with the decisions it allows" do
      expect(assistants.tool_calls_under_review(thread_id:)).to eq(
        [
          {
            "previous_message_id" => "communication-1",
            "id" => "tool_call_id_2",
            "name" => "send_invoice",
            "args" => { "amount" => 100 },
            "allowed_decisions" => %w[approve reject],
          },
        ]
      )
    end

    context "when the thread is not waiting on a review" do
      let(:interrupts) { [] }

      it "returns an empty array" do
        expect(assistants.tool_calls_under_review(thread_id:)).to eq([])
      end
    end

    context "when the thread state cannot be fetched" do
      before do
        stub_json(:get, state_url, { error: "Internal Server Error" }, status: 500)
      end

      it "raises ThreadResumptionError" do
        expect do
          assistants.tool_calls_under_review(thread_id:)
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          '{"error":"Internal Server Error"}'
        )
      end
    end
  end

  describe "#review_tool_calls" do
    include_context "with an Assistants thread"

    let(:assistant_id) { "assistant-789" }
    let(:thread_status) { "interrupted" }
    let(:tool_calls) do
      {
        "tool_call_id_1" => {
          "action" => "approve",
        },
        "tool_call_id_2" => {
          "action" => "edit",
          "args" => {
            "arg_1" => "new value",
          },
        },
      }
    end
    let(:messages) do
      [
        {
          "type" => "human",
          "id" => "communication-1",
          "content" => "Please look up my account",
        },
        {
          "type" => "ai",
          "id" => "ai-message-1",
          "content" => "",
          "tool_calls" => [
            {
              "id" => "tool_call_id_1",
              "name" => "lookup_account",
              "args" => {},
            },
            {
              "id" => "tool_call_id_2",
              "name" => "lookup_orders",
              "args" => {
                "arg_1" => "original value",
                "arg_2" => "original value",
              },
            },
          ],
        },
      ]
    end
    let(:allowed_decisions) { %w[approve edit reject respond] }
    let(:interrupt_value) do
      {
        "action_requests" => [
          {
            "name" => "lookup_account",
            "args" => {},
            "description" => "Tool execution requires approval",
          },
          {
            "name" => "lookup_orders",
            "args" => {
              "arg_1" => "original value",
              "arg_2" => "original value",
            },
            "description" => "Tool execution requires approval",
          },
        ],
        "review_configs" => [
          { "action_name" => "lookup_account", "allowed_decisions" => allowed_decisions },
          { "action_name" => "lookup_orders", "allowed_decisions" => allowed_decisions },
        ],
      }
    end
    let(:thread) do
      {
        "thread_id" => thread_id,
        "status" => thread_status,
      }
    end
    let(:thread_state) do
      {
        "values" => {
          "messages" => messages,
        },
        "interrupts" => [
          { "value" => interrupt_value },
        ],
      }
    end
    let(:decisions) do
      [
        { "type" => "approve" },
        {
          "type" => "edit",
          "edited_action" => {
            "name" => "lookup_orders",
            "args" => {
              "arg_1" => "new value",
              "arg_2" => "original value",
            },
          },
        },
      ]
    end
    let(:context) { {} }
    let(:resume_request_body) do
      {
        assistant_id:,
        command: {
          resume: { decisions: },
        },
        context:,
      }
    end
    let(:run_response_body) do
      {
        "messages" => [
          { "role" => "assistant", "content" => "Reviewed response" },
        ],
      }
    end

    before do
      stub_json(:get, thread_url, thread)

      stub_json(:get, state_url, thread_state)

      stub_json(:post, run_url, run_response_body, request_body: resume_request_body)
    end

    it "fetches the thread and thread state before resuming reviewed tool calls" do
      assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)

      expect(WebMock).to have_requested(:get, thread_url)
      expect(WebMock).to have_requested(:get, state_url)
    end

    it "resumes with one decision per action request, in the interrupt's order" do
      assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)

      expect(WebMock).to have_requested(:post, run_url)
        .with(body: resume_request_body.to_json)
    end

    it "returns nil" do
      result = assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)

      expect(result).to be_nil
    end

    context "when the resumed run fails inside a successful response" do
      let(:run_response_body) do
        {
          "__error__" => {
            "error" => "Error",
            "message" => "RuntimeError: tool blew up",
          },
        }
      end

      it "raises ThreadResumptionError rather than reporting the review as applied" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Error: RuntimeError: tool blew up"
        )
      end
    end

    context "when a reviewer rejects and responds instead" do
      let(:tool_calls) do
        {
          "tool_call_id_1" => { "action" => "reject", "message" => "Wrong account" },
          "tool_call_id_2" => { "action" => "respond", "message" => "There are no open orders" },
        }
      end
      let(:decisions) do
        [
          { "type" => "reject", "message" => "Wrong account" },
          { "type" => "respond", "message" => "There are no open orders" },
        ]
      end

      it "sends both messages with their decisions" do
        assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)

        expect(WebMock).to have_requested(:post, run_url)
          .with(body: resume_request_body.to_json)
      end
    end

    context "when the caller supplies a context" do
      let(:context) { { "prompt_variables" => { "customer_name" => "Casey" } } }

      it "sends it with the resumed run" do
        assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:, context:)

        expect(WebMock).to have_requested(:post, run_url)
          .with(body: resume_request_body.to_json)
      end
    end

    context "when the thread does not exist" do
      before do
        stub_json(:get, thread_url, {}, status: 404)
      end

      it "raises ThreadResumptionError" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadResumptionError, "{}")
      end

      it "does not attempt to resume the thread" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadResumptionError)

        expect(WebMock).not_to have_requested(:get, state_url)
        expect(WebMock).not_to have_requested(:post, run_url)
      end
    end

    context "when the thread is no longer interrupted" do
      let(:thread_status) { "idle" }

      it "raises ThreadResumptionError" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Thread #{thread_id} is not in the interrupted state"
        )
      end

      it "does not attempt to resume the thread" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadResumptionError)

        expect(WebMock).not_to have_requested(:get, state_url)
        expect(WebMock).not_to have_requested(:post, run_url)
      end
    end

    context "when the interrupt is holding no tool calls" do
      let(:interrupt_value) { { "action_requests" => [], "review_configs" => [] } }

      it "raises ThreadResumptionError" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Thread #{thread_id} has no tool calls awaiting review"
        )
      end

      it "does not attempt to resume the thread" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadResumptionError)

        expect(WebMock).not_to have_requested(:post, run_url)
      end
    end

    context "when the review includes a tool call that is not under review" do
      let(:tool_calls) do
        super().merge(
          "tool_call_id_3" => {
            "action" => "approve",
          }
        )
      end

      it "raises ThreadResumptionError" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Unknown tool call ids: tool_call_id_3"
        )
      end

      it "does not attempt to resume the thread" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadResumptionError)

        expect(WebMock).not_to have_requested(:post, run_url)
      end
    end

    context "when a review action is not among the interrupt's allowed decisions" do
      let(:allowed_decisions) { ["approve"] }

      it "raises ThreadResumptionError" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Invalid review action `edit` for tool call tool_call_id_2"
        )
      end

      it "does not attempt to resume the thread" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadResumptionError)

        expect(WebMock).not_to have_requested(:post, run_url)
      end
    end

    context "when edited arguments do not match the pending tool call" do
      let(:tool_calls) do
        super().merge(
          "tool_call_id_2" => {
            "action" => "edit",
            "args" => {
              "arg_3" => "new value",
            },
          }
        )
      end

      it "raises ThreadResumptionError" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Invalid edited args for tool call tool_call_id_2: arg_3"
        )
      end

      it "does not attempt to resume the thread" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadResumptionError)

        expect(WebMock).not_to have_requested(:post, run_url)
      end
    end

    context "when resuming the thread fails" do
      before do
        stub_json(:post, run_url, { error: "Internal Server Error" }, status: 500, request_body: resume_request_body)
      end

      it "raises ThreadResumptionError" do
        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls:)
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          '{"error":"Internal Server Error"}'
        )
      end
    end
  end

  describe "#thread_state" do
    include_context "with an Assistants thread"

    let(:thread_state) do
      {
        "values" => {
          "messages" => [
            {
              "type" => "human",
              "id" => "communication-1",
              "content" => "Hello",
            },
            {
              "type" => "ai",
              "id" => "ai-message-1",
              "content" => "Hi there!",
            },
          ],
        },
        "next" => [],
      }
    end

    context "when the thread state is fetched successfully" do
      before do
        stub_json(:get, state_url, thread_state)
      end

      it "returns the thread state as reported by Assistants" do
        expect(assistants.thread_state(thread_id:)).to eq(thread_state)
      end

      it "authenticates the request" do
        assistants.thread_state(thread_id:)

        expect(WebMock).to have_requested(:get, state_url)
          .with(headers: { "Authorization" => "Bearer #{api_key}" })
      end
    end

    context "when the thread state cannot be fetched" do
      before do
        stub_json(:get, state_url, { "detail" => "Thread not found" }, status: 404)
      end

      it "raises ThreadStateError carrying the response body" do
        expect do
          assistants.thread_state(thread_id:)
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadStateError,
          { "detail" => "Thread not found" }.to_json
        )
      end
    end
  end

  describe "#thread_messages" do
    include_context "with an Assistants thread"

    let(:messages) do
      [
        {
          "type" => "human",
          "id" => "communication-1",
          "content" => "Hello",
        },
        {
          "type" => "ai",
          "id" => "ai-message-1",
          "content" => "Hi there!",
        },
      ]
    end

    before do
      stub_json(:get, state_url, thread_state)
    end

    context "when the thread has messages" do
      let(:thread_state) { { "values" => { "messages" => messages } } }

      it "returns the messages as reported by Assistants" do
        expect(assistants.thread_messages(thread_id:)).to eq(messages)
      end
    end

    context "when the thread has no messages" do
      let(:thread_state) { { "values" => {} } }

      it "returns an empty array" do
        expect(assistants.thread_messages(thread_id:)).to eq([])
      end
    end

    context "when the thread has no state values" do
      let(:thread_state) { {} }

      it "returns an empty array" do
        expect(assistants.thread_messages(thread_id:)).to eq([])
      end
    end

    context "when the thread state cannot be fetched" do
      let(:thread_state) { {} }

      before do
        stub_request(:get, state_url)
          .to_return(
            status: 500,
            body: "boom",
            headers: { "Content-Type" => "text/plain" }
          )
      end

      it "raises ThreadStateError" do
        expect do
          assistants.thread_messages(thread_id:)
        end.to raise_error(NitroIntelligence::Assistants::ThreadStateError, "boom")
      end
    end
  end

  describe "#tool_calls_pending_review" do
    include_context "with an Assistants thread"

    let(:thread_state) do
      {
        "values" => {
          "messages" => messages,
        },
      }
    end

    before do
      stub_json(:get, state_url, thread_state)
    end

    context "when an AI message is the first message in the thread" do
      let(:messages) do
        [
          {
            "type" => "ai",
            "id" => "ai-message-1",
            "content" => "",
            "tool_calls" => [
              {
                "id" => "tool_call_id_1",
                "name" => "lookup_account",
                "args" => {},
              },
            ],
          },
        ]
      end

      it "returns nil as the previous message id" do
        expect(assistants.tool_calls_pending_review(thread_id:)).to eq(
          [
            {
              "previous_message_id" => nil,
              "id" => "tool_call_id_1",
              "name" => "lookup_account",
              "args" => {},
            },
          ]
        )
      end
    end

    context "when an AI message has tool calls without matching tool messages" do
      let(:messages) do
        [
          {
            "type" => "human",
            "id" => "communication-1",
            "content" => "Please look up my account",
          },
          {
            "type" => "ai",
            "id" => "ai-message-1",
            "content" => "",
            "tool_calls" => [
              {
                "id" => "tool_call_id_1",
                "name" => "lookup_account",
                "args" => {},
              },
              {
                "id" => "tool_call_id_2",
                "name" => "lookup_orders",
                "args" => {
                  "status" => "open",
                },
              },
            ],
          },
        ]
      end

      it "returns all pending tool calls with the previous message id" do
        expect(assistants.tool_calls_pending_review(thread_id:)).to eq(
          [
            {
              "previous_message_id" => "communication-1",
              "id" => "tool_call_id_1",
              "name" => "lookup_account",
              "args" => {},
            },
            {
              "previous_message_id" => "communication-1",
              "id" => "tool_call_id_2",
              "name" => "lookup_orders",
              "args" => {
                "status" => "open",
              },
            },
          ]
        )
      end
    end

    context "when some tool calls already have matching tool messages" do
      let(:messages) do # rubocop:disable Metrics/BlockLength
        [
          {
            "type" => "human",
            "id" => "communication-1",
            "content" => "Check my account",
          },
          {
            "type" => "ai",
            "id" => "ai-message-1",
            "content" => "",
            "tool_calls" => [
              {
                "id" => "tool_call_id_1",
                "name" => "lookup_account",
                "args" => {},
              },
              {
                "id" => "tool_call_id_2",
                "name" => "lookup_orders",
                "args" => {
                  "status" => "open",
                },
              },
            ],
          },
          {
            "type" => "tool",
            "id" => "tool-message-1",
            "tool_call_id" => "tool_call_id_1",
            "content" => "Account found",
          },
          {
            "type" => "human",
            "id" => "communication-2",
            "content" => "Also check my invoices",
          },
          {
            "type" => "ai",
            "id" => "ai-message-2",
            "content" => "",
            "tool_calls" => [
              {
                "id" => "tool_call_id_3",
                "name" => "lookup_invoices",
                "args" => {
                  "limit" => 5,
                },
              },
            ],
          },
        ]
      end

      it "excludes tool calls that already have tool messages" do
        expect(assistants.tool_calls_pending_review(thread_id:)).to eq(
          [
            {
              "previous_message_id" => "communication-1",
              "id" => "tool_call_id_2",
              "name" => "lookup_orders",
              "args" => {
                "status" => "open",
              },
            },
            {
              "previous_message_id" => "communication-2",
              "id" => "tool_call_id_3",
              "name" => "lookup_invoices",
              "args" => {
                "limit" => 5,
              },
            },
          ]
        )
      end
    end

    context "when every tool call has already been handled" do
      let(:messages) do
        [
          {
            "type" => "human",
            "id" => "communication-1",
            "content" => "Check my account",
          },
          {
            "type" => "ai",
            "id" => "ai-message-1",
            "content" => "",
            "tool_calls" => [
              {
                "id" => "tool_call_id_1",
                "name" => "lookup_account",
                "args" => {},
              },
            ],
          },
          {
            "type" => "tool",
            "id" => "tool-message-1",
            "tool_call_id" => "tool_call_id_1",
            "content" => "Account found",
          },
        ]
      end

      it "returns an empty array" do
        expect(assistants.tool_calls_pending_review(thread_id:)).to eq([])
      end
    end
  end

  describe "runs that pause for review" do
    include_context "with an Assistants thread"

    let(:assistant_id) { "assistant-789" }
    let(:reviewer_id) { "jane@example.com" }
    let(:reviewed_at) { "2026-10-18T14:03:00Z" }
    let(:context) { { "prompt_variables" => { "first_name" => "Casey" } } }
    let(:draft) { "Sure! You're booked for Tuesday at 10am." }
    let(:human_message) { { "type" => "human", "id" => "human-1", "content" => "Can I move it to Tuesday?" } }
    let(:draft_message) { { "type" => "ai", "id" => "ai-2", "content" => draft } }
    let(:tool_message) do
      {
        "type" => "ai",
        "id" => "ai-1",
        "content" => "Let me cancel that.",
        "tool_calls" => [{ "id" => "call-1", "name" => "cancel_appointment", "args" => { "id" => 7 } }],
      }
    end
    let(:tool_result) { { "type" => "tool", "id" => "tool-1", "tool_call_id" => "call-1", "content" => "Cancelled" } }
    let(:reply_interrupt) { reply_interrupt_for(draft, description: "Review this SMS") }
    let(:tool_interrupt) { tool_interrupt_for("cancel_appointment", { "id" => 7 }) }

    describe "#run" do
      let(:messages) { [{ role: "user", content: "Can I move it to Tuesday?" }] }
      let(:run_response_body) { { "messages" => [human_message, draft_message] } }

      before do
        stub_json(:get, "#{base_url}/assistants/#{assistant_id}", { "graph_id" => "confirmation-agent" })
        stub_json(:post, "#{base_url}/threads", {}, status: 409)
        stub_json(:post, run_url, run_response_body)
      end

      it "returns the reply of a run that ended" do
        result = assistants.run(thread_id:, assistant_id:, messages:, context:)

        expect(result).to be_a(NitroIntelligence::RunResult)
        expect(result).not_to be_interrupted
        expect(result.reply).to eq(draft)
      end

      context "when the run pauses on its reply" do
        let(:run_response_body) { { "messages" => [human_message, draft_message], "__interrupt__" => [reply_interrupt] } }

        it "holds the draft back and reports it for review" do
          result = assistants.run(thread_id:, assistant_id:, messages:, context:)

          expect(result).to be_interrupted
          expect(result.reply).to be_nil
          expect(result.review.reply).to have_attributes(
            content: draft, allowed_decisions: %w[approve edit reject], description: "Review this SMS",
            interrupt_id: "interrupt-reply"
          )
        end

        it "makes #await_run return nil rather than the draft" do
          expect(assistants.await_run(thread_id:, assistant_id:, messages:, context:)).to be_nil
        end
      end

      context "when the run pauses on tool calls" do
        let(:run_response_body) { { "messages" => [human_message, tool_message], "__interrupt__" => [tool_interrupt] } }

        it "reports the tool calls, and makes #await_run return nil rather than the working text" do
          result = assistants.run(thread_id:, assistant_id:, messages:, context:)

          expect(result.review.tool_calls.map { |tool_call| tool_call["id"] }).to eq(["call-1"])
          expect(assistants.await_run(thread_id:, assistant_id:, messages:, context:)).to be_nil
        end
      end

      context "when the reply was delivered" do
        let(:delivered) do
          draft_message.merge(
            "response_metadata" => { "delivery" => { "status" => "delivered", "tool" => "send_sms", "attempts" => 1 } }
          )
        end
        let(:run_response_body) { { "messages" => [human_message, delivered] } }

        it "reports the delivery with the reply" do
          result = assistants.run(thread_id:, assistant_id:, messages:, context:)

          expect(result.reply).to eq(draft)
          expect(result.delivery).to have_attributes(status: "delivered", attempts: 1)
        end
      end
    end

    describe "#under_review" do
      it "reads the pending review from the thread state" do
        stub_paused_thread(messages: [human_message, draft_message], interrupt: reply_interrupt)

        expect(assistants.under_review(thread_id:).reply.content).to eq(draft)
      end

      it "is nil when the thread is not paused" do
        stub_paused_thread(messages: [human_message, draft_message], interrupt: nil, status: "idle")

        expect(assistants.under_review(thread_id:)).to be_nil
      end

      it "raises ThreadStateError when the state cannot be read" do
        stub_json(:get, state_url, { "error" => "boom" }, status: 500)

        expect { assistants.under_review(thread_id:) }
          .to raise_error(NitroIntelligence::Assistants::ThreadStateError, '{"error":"boom"}')
      end
    end

    describe "#tool_calls_under_review on a reply pause" do
      it "returns an empty array instead of failing to match __reply__ to a tool call" do
        stub_paused_thread(messages: [human_message, draft_message], interrupt: reply_interrupt)

        expect(assistants.tool_calls_under_review(thread_id:)).to eq([])
      end
    end

    describe "#review_tool_calls" do
      it "refuses a reply pause, as it does any pause holding no tool calls" do
        stub_paused_thread(messages: [human_message, draft_message], interrupt: reply_interrupt)

        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls: {})
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Thread #{thread_id} has no tool calls awaiting review"
        )
      end

      it "takes a list of reviews that each carry their tool call's id" do
        stub_paused_thread(messages: [human_message, tool_message], interrupt: tool_interrupt)
        stub_json(:post, run_url, { "messages" => [human_message, tool_message, tool_result] })

        assistants.review_tool_calls(thread_id:, assistant_id:, context:,
                                     tool_calls: [{ "id" => "call-1", "action" => "reject", "message" => "No" }])

        decisions = [{ "type" => "reject", "message" => "No" }]
        expect(WebMock).to have_requested(:post, run_url)
          .with(body: hash_including("command" => { "resume" => { "interrupt-tools" => { "decisions" => decisions } } }))
      end
    end

    # The resume #review sends: decisions keyed by the interrupt, with the reviewer in each decision
    # and in the run's config.metadata.
    def resume_body(decisions, interrupt_id: "interrupt-reply", reviewed_at: self.reviewed_at)
      stamp = { "reviewer_id" => reviewer_id, "reviewed_at" => reviewed_at }
      {
        assistant_id:,
        command: { resume: { interrupt_id => { decisions: decisions.map { |decision| decision.merge(stamp) } } } },
        config: { metadata: stamp },
        context:,
      }
    end

    describe "#review_tool_calls with a reviewer" do
      before do
        stub_paused_thread(messages: [human_message, tool_message], interrupt: tool_interrupt)
        stub_json(:post, run_url, { "messages" => [human_message, tool_message, tool_result] })
      end

      it "puts the reviewer in each decision and in config.metadata, as #review does" do
        result = assistants.review_tool_calls(
          thread_id:, assistant_id:, reviewer_id:, reviewed_at:, context:,
          tool_calls: { "call-1" => { "action" => "approve" } }
        )

        expect(result).to be_nil
        expect(WebMock).to have_requested(:post, run_url)
          .with(body: resume_body([{ "type" => "approve" }], interrupt_id: "interrupt-tools").to_json)
      end

      it "sends neither without one" do
        assistants.review_tool_calls(thread_id:, assistant_id:, context:,
                                     tool_calls: { "call-1" => { "action" => "approve" } })

        expect(WebMock).to have_requested(:post, run_url).with(
          body: {
            assistant_id:, command: { resume: { "interrupt-tools" => { decisions: [{ "type" => "approve" }] } } }, context:
          }.to_json
        )
      end

      it "raises a resume Assistants refuses as the raw body, not as superseded, for callers that parse it" do
        refusal = { "detail" => "Cannot resume: thread is not in interrupted state" }
        stub_json(:post, run_url, refusal, status: 400)

        expect do
          assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls: { "call-1" => { "action" => "approve" } })
        end.to raise_error(
          an_instance_of(NitroIntelligence::Assistants::ThreadResumptionError).and(
            having_attributes(message: refusal.to_json)
          )
        )
      end
    end

    describe "#review" do
      before do
        stub_paused_thread(messages: [human_message, draft_message], interrupt: reply_interrupt)
        stub_json(:post, run_url, { "messages" => [human_message, draft_message] })
      end

      # A reply review names the interrupt the reviewer was shown; a tool call review need not.
      def review(**kwargs)
        kwargs = { interrupt_id: "interrupt-reply" }.merge(kwargs) if kwargs.key?(:reply)
        assistants.review(thread_id:, assistant_id:, reviewer_id:, reviewed_at:, context:, **kwargs)
      end

      it "approves the reply, with the reviewer in the decision and in config.metadata" do
        result = review(reply: { "action" => "approve" }, interrupt_id: "interrupt-reply")

        expect(WebMock).to have_requested(:post, run_url).with(body: resume_body([{ "type" => "approve" }]).to_json)
        expect(result).to be_a(NitroIntelligence::RunResult)
        expect(result.reply).to eq(draft)
      end

      it "edits the reply" do
        edited = draft_message.merge(
          "content" => "Tuesday at 10am works.",
          "response_metadata" => { "delivery" => { "status" => "delivered", "attempts" => 1 } }
        )
        stub_json(:post, run_url, { "messages" => [human_message, edited] })

        result = review(reply: { "action" => "edit", "content" => "Tuesday at 10am works." })

        edit = { "type" => "edit", "edited_action" => { "name" => "__reply__", "args" => { "content" => "Tuesday at 10am works." } } }
        expect(WebMock).to have_requested(:post, run_url).with(body: resume_body([edit]).to_json)
        expect(result.reply).to eq("Tuesday at 10am works.")
        expect(result.delivery.status).to eq("delivered")
      end

      it "rejects the reply with a reason, and returns no reply" do
        stub_json(:post, run_url, { "messages" => [human_message] })

        result = review(reply: { "action" => "reject", "message" => "Wrong appointment" })

        expect(WebMock).to have_requested(:post, run_url)
          .with(body: resume_body([{ "type" => "reject", "message" => "Wrong appointment" }]).to_json)
        expect(result.reply).to be_nil
      end

      it "returns no reply when the rejected draft followed a tool turn, rather than that turn's text" do
        stub_json(:post, run_url, { "messages" => [human_message, tool_message, tool_result] })

        expect(review(reply: { "action" => "reject" }).reply).to be_nil
      end

      it "stamps the current time when reviewed_at is not given" do
        allow(Time).to receive(:now).and_return(Time.utc(2026, 10, 21, 12, 0, 0))

        assistants.review(thread_id:, assistant_id:, reviewer_id:, context:, interrupt_id: "interrupt-reply",
                          reply: { "action" => "approve" })

        expect(WebMock).to have_requested(:post, run_url)
          .with(body: resume_body([{ "type" => "approve" }], reviewed_at: "2026-10-21T12:00:00Z").to_json)
      end

      it "stamps a reviewed_at given as a Time in UTC" do
        review(reply: { "action" => "approve" }, reviewed_at: Time.new(2026, 10, 21, 8, 0, 0, "-04:00"))

        expect(WebMock).to have_requested(:post, run_url)
          .with(body: resume_body([{ "type" => "approve" }], reviewed_at: "2026-10-21T12:00:00Z").to_json)
      end

      it "refuses respond for a reply, sending nothing" do
        expect { review(reply: { "action" => "respond", "message" => "Hi" }) }.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Invalid review action `respond` for the reply; allowed: approve, edit, reject"
        )
        expect(WebMock).not_to have_requested(:post, run_url)
      end

      it "requires a reviewer" do
        expect do
          assistants.review(thread_id:, assistant_id:, reviewer_id: "", reply: { "action" => "approve" })
        end.to raise_error(ArgumentError, "reviewer_id is required")
      end

      it "requires the interrupt the reviewer was shown for a reply, sending nothing" do
        expect do
          assistants.review(thread_id:, assistant_id:, reviewer_id:, context:, reply: { "action" => "approve" })
        end.to raise_error(ArgumentError, /interrupt_id is required to review a reply/)
        expect(WebMock).not_to have_requested(:any, /#{base_url}/)
      end

      it "requires exactly one thing to review" do
        expect { review(reply: { "action" => "approve" }, tool_calls: {}) }
          .to raise_error(ArgumentError, "pass exactly one of reply: or tool_calls:")
        expect { review }.to raise_error(ArgumentError, "pass exactly one of reply: or tool_calls:")
      end

      context "when a new message superseded the review the reviewer was shown" do
        before do
          stub_paused_thread(messages: [human_message, draft_message],
                             interrupt: reply_interrupt.merge("id" => "interrupt-newer"))
        end

        it "refuses as superseded instead of deciding the newer draft, sending nothing" do
          expect { review(reply: { "action" => "approve" }, interrupt_id: "interrupt-reply") }.to raise_error(
            NitroIntelligence::Assistants::ReviewSupersededError,
            "Thread #{thread_id} is no longer paused on interrupt-reply: another review already resumed it, " \
            "or a new message superseded it"
          )
          expect(WebMock).not_to have_requested(:post, run_url)
        end

        it "is still a ThreadResumptionError for callers that rescue that" do
          expect { review(reply: { "action" => "approve" }, interrupt_id: "interrupt-reply") }
            .to raise_error(NitroIntelligence::Assistants::ThreadResumptionError)
        end
      end

      context "when the thread is no longer paused" do
        before { stub_paused_thread(messages: [human_message, draft_message], interrupt: nil, status: "idle") }

        it "refuses as superseded" do
          expect { review(reply: { "action" => "approve" }, interrupt_id: "interrupt-reply") }
            .to raise_error(NitroIntelligence::Assistants::ReviewSupersededError)
          expect(WebMock).not_to have_requested(:post, run_url)
        end
      end

      context "when the thread's run is under way again" do
        before { stub_paused_thread(messages: [human_message, draft_message], interrupt: reply_interrupt, status: "busy") }

        it "refuses as superseded without reading the stale interrupt" do
          expect { review(reply: { "action" => "approve" }) }
            .to raise_error(NitroIntelligence::Assistants::ReviewSupersededError, /no longer paused on interrupt-reply/)
        end
      end

      context "when another review resumes the thread between the check and the resume" do
        before do
          stub_json(:post, run_url, { "detail" => "Cannot resume: thread is not in interrupted state" }, status: 400)
        end

        it "reports the review Assistants refused as superseded, since the first resume won" do
          expect { review(reply: { "action" => "approve" }, interrupt_id: "interrupt-reply") }.to raise_error(
            NitroIntelligence::Assistants::ReviewSupersededError, /no longer paused on interrupt-reply/
          )
        end
      end

      context "when the resume fails for another reason" do
        before { stub_json(:post, run_url, { "detail" => "boom" }, status: 500) }

        it "raises the failure as a ThreadResumptionError, not as superseded" do
          expect { review(reply: { "action" => "approve" }) }.to raise_error(
            an_instance_of(NitroIntelligence::Assistants::ThreadResumptionError).and(
              having_attributes(message: '{"detail":"boom"}')
            )
          )
        end
      end

      context "when the resumed run fails inside a successful response" do
        before { stub_json(:post, run_url, { "__error__" => { "error" => "Error", "message" => "tool blew up" } }) }

        it "raises the run's error as a ThreadResumptionError, not as superseded" do
          expect { review(reply: { "action" => "approve" }) }.to raise_error(
            an_instance_of(NitroIntelligence::Assistants::ThreadResumptionError).and(
              having_attributes(message: "Error: tool blew up")
            )
          )
        end
      end

      context "when the thread is paused on tool calls" do
        before do
          stub_paused_thread(messages: [human_message, tool_message], interrupt: tool_interrupt)
          stub_json(:post, run_url, { "messages" => [human_message, tool_message, tool_result, draft_message] })
        end

        it "refuses a reply review, sending nothing" do
          expect { review(reply: { "action" => "approve" }, interrupt_id: "interrupt-tools") }.to raise_error(
            NitroIntelligence::Assistants::ThreadResumptionError,
            "Thread #{thread_id} is awaiting review of tool calls, not of a reply"
          )
          expect(WebMock).not_to have_requested(:post, run_url)
        end

        it "decides them from a list of reviews, with the reviewer in each decision and in config.metadata" do
          result = review(tool_calls: [{ "id" => "call-1", "action" => "reject", "message" => "Customer called in" }],
                          interrupt_id: "interrupt-tools")

          expect(WebMock).to have_requested(:post, run_url).with(
            body: resume_body([{ "type" => "reject", "message" => "Customer called in" }],
                              interrupt_id: "interrupt-tools").to_json
          )
          expect(result.reply).to eq(draft)
        end

        it "takes them without the interrupt the reviewer was shown, keyed by the one it read" do
          review(tool_calls: { "call-1" => { "action" => "approve" } })

          expect(WebMock).to have_requested(:post, run_url)
            .with(body: resume_body([{ "type" => "approve" }], interrupt_id: "interrupt-tools").to_json)
        end

        it "refuses a review of a tool call the interrupt is not holding, sending nothing" do
          expect { review(tool_calls: { "call-9" => { "action" => "approve" } }) }.to raise_error(
            NitroIntelligence::Assistants::ThreadResumptionError, "Unknown tool call ids: call-9"
          )
          expect(WebMock).not_to have_requested(:post, run_url)
        end

        it "refuses reviews that leave a held tool call undecided, sending nothing" do
          expect { review(tool_calls: {}) }.to raise_error(
            NitroIntelligence::Assistants::ThreadResumptionError, "Missing reviews for tool calls: call-1"
          )
          expect(WebMock).not_to have_requested(:post, run_url)
        end
      end
    end

    describe "keyed resumes" do
      let(:tools_state) { { "values" => { "messages" => [human_message, tool_message] }, "interrupts" => [tool_interrupt] } }
      let(:reply_paused_run) do
        { "messages" => [human_message, tool_message, tool_result, draft_message], "__interrupt__" => [reply_interrupt] }
      end

      def reply_state(written_by:)
        {
          "values" => { "messages" => [human_message, tool_message, tool_result, draft_message] },
          "interrupts" => [reply_interrupt],
          "metadata" => { "run_id" => written_by, "step" => 4 },
        }
      end

      def review_tools(**kwargs)
        assistants.review(thread_id:, assistant_id:, reviewer_id:, reviewed_at:, context:,
                          tool_calls: { "call-1" => { "action" => "approve" } }, **kwargs)
      end

      before { stub_json(:get, thread_url, { "thread_id" => thread_id, "status" => "interrupted" }) }

      context "when the resume was applied and the run paused again on its reply" do
        before do
          stub_states(tools_state, reply_state(written_by: "run-mine"))
          stub_resume(reply_paused_run, run_id: "run-mine")
        end

        it "returns the new pause" do
          expect(review_tools.review.reply.content).to eq(draft)
        end
      end

      # Another reviewer's resume decided the tool calls between this review's read and its resume,
      # and the run's reply paused at once. Keyed by the tool call interrupt, this resume decided
      # nothing, so the latest checkpoint is still the one the other reviewer's run wrote.
      context "when another review's resume moved the thread on between the read and the resume" do
        before do
          stub_states(tools_state, reply_state(written_by: "run-theirs"))
          stub_resume(reply_paused_run, run_id: "run-mine")
        end

        it "refuses as superseded, rather than reporting the reply pause as this review's" do
          expect { review_tools }.to raise_error(
            NitroIntelligence::Assistants::ReviewSupersededError,
            "Thread #{thread_id} is no longer paused on interrupt-tools: another review already resumed it, " \
            "or a new message superseded it; it is now paused on interrupt-reply, and the decision was not applied"
          )
        end

        it "refuses the same through #review_tool_calls" do
          expect do
            assistants.review_tool_calls(thread_id:, assistant_id:, tool_calls: { "call-1" => { "action" => "approve" } })
          end.to raise_error(NitroIntelligence::Assistants::ReviewSupersededError, /the decision was not applied/)
        end
      end

      context "when the wait does not say which run it was" do
        before do
          stub_states(tools_state, reply_state(written_by: "run-theirs"))
          stub_json(:post, run_url, reply_paused_run)
        end

        it "returns the pause, since nothing shows the decision was not applied" do
          expect(review_tools.review.reply).to be_present
          expect(WebMock).to have_requested(:get, state_url).once
        end
      end

      context "when the state cannot be read after the resume" do
        before do
          stub_request(:get, state_url)
            .to_return(status: 200, body: tools_state.to_json, headers: AssistantsHelpers::JSON_HEADERS)
            .then.to_return(status: 500, body: "boom")
          stub_resume(reply_paused_run, run_id: "run-mine")
        end

        it "returns the pause, as the resume itself succeeded" do
          expect(review_tools.review.reply).to be_present
        end
      end

      context "when the interrupt reports no id" do
        before do
          stub_states({ "values" => { "messages" => [human_message, tool_message] },
                        "interrupts" => [tool_interrupt.except("id")] }, {})
          stub_resume({ "messages" => [human_message, tool_message, tool_result] })
        end

        it "resumes unkeyed, the only resume such a pause takes" do
          review_tools

          stamp = { "reviewer_id" => reviewer_id, "reviewed_at" => reviewed_at }
          expect(WebMock).to have_requested(:post, run_url).with(
            body: {
              assistant_id:, command: { resume: { decisions: [{ "type" => "approve" }.merge(stamp)] } },
              config: { metadata: stamp }, context:
            }.to_json
          )
        end
      end
    end
  end
end
