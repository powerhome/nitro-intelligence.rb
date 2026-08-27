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
  end

  describe "deprecated agent server names" do
    let(:base_url) { "https://assistants.example.com" }
    let(:api_key) { "test-api-key" }

    around do |example|
      original_behavior = NitroIntelligence.deprecator.behavior
      NitroIntelligence.deprecator.behavior = :silence
      example.run
      NitroIntelligence.deprecator.behavior = original_behavior
    end

    after do
      NitroIntelligence.configuration.assistants_config = {}
      NitroIntelligence.configuration.agent_server_config = nil
    end

    describe "NitroIntelligence::AgentServer" do
      it "resolves to NitroIntelligence::Assistants itself" do
        expect(NitroIntelligence::AgentServer).to be(NitroIntelligence::Assistants)
      end

      it "still matches an Assistants instance, so type checks survive the rename" do
        assistants = NitroIntelligence::Assistants.new(base_url:, api_key:)

        expect(assistants).to be_a(NitroIntelligence::AgentServer)
      end

      it "resolves the errors nested under NitroIntelligence::Assistants" do
        expect(NitroIntelligence::AgentServer::ThreadResumptionError)
          .to be(NitroIntelligence::Assistants::ThreadResumptionError)
      end

      it "warns when it is referenced" do
        expect(NitroIntelligence.deprecator).to receive(:warn).at_least(:once)

        NitroIntelligence::AgentServer
      end
    end

    describe ".agent_server" do
      before do
        NitroIntelligence.configuration.assistants_config = {
          "base_url" => base_url,
          "api_key" => api_key,
        }
      end

      it "returns an instance of Assistants" do
        expect(described_class.agent_server).to be_a(NitroIntelligence::Assistants)
      end

      it "warns that it is deprecated" do
        expect(NitroIntelligence.deprecator).to receive(:warn).with(/`NitroIntelligence.agent_server` is deprecated/)

        described_class.agent_server
      end
    end

    describe "agent_server_config" do
      before do
        NitroIntelligence.configuration.agent_server_config = {
          "base_url" => base_url,
          "api_key" => api_key,
          "user_id" => "legacy-user",
        }
      end

      it "configures Assistants when assistants_config is unset" do
        expect(described_class.assistants.user_id).to eq("legacy-user")
      end

      it "warns that it is deprecated" do
        expect(NitroIntelligence.deprecator).to receive(:warn).with(/`agent_server_config` is deprecated/)

        described_class.assistants
      end

      it "is ignored when assistants_config is also set" do
        NitroIntelligence.configuration.assistants_config = {
          "base_url" => base_url,
          "api_key" => api_key,
          "user_id" => "current-user",
        }

        expect(described_class.assistants.user_id).to eq("current-user")
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
      it "raises ConfigurationError when base_url is nil" do
        expect do
          described_class.new(base_url: nil, api_key:, user_id:)
        end.to raise_error(NitroIntelligence::Assistants::ConfigurationError, "base_url is required")
      end

      it "raises ConfigurationError when base_url is empty" do
        expect do
          described_class.new(base_url: "", api_key:, user_id:)
        end.to raise_error(NitroIntelligence::Assistants::ConfigurationError, "base_url is required")
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
    let(:thread_id) { "thread-456" }
    let(:assistant_id) { "assistant-789" }
    let(:context) { { key: "value" } }
    let(:graph_id) { "confirmation-agent" }
    let(:assistant_url) { "#{base_url}/assistants/#{assistant_id}" }
    let(:thread_init_url) { "#{base_url}/threads" }
    let(:thread_url) { "#{base_url}/threads/#{thread_id}" }
    let(:thread_state_url) { "#{base_url}/threads/#{thread_id}/state" }
    let(:run_url) { "#{base_url}/threads/#{thread_id}/runs/wait" }

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
      stub_request(:get, assistant_url)
        .to_return(
          status: 200,
          body: { assistant_id:, name: graph_id, graph_id: }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:post, thread_init_url)
        .with(body: thread_init_request_body.to_json)
        .to_return(
          status: 200,
          body: {}.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:post, thread_state_url)
        .with(body: thread_state_request_body.to_json)
        .to_return(
          status: 200,
          body: {}.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:post, run_url)
        .with(body: run_request_body.to_json)
        .to_return(
          status: 200,
          body: run_response_body.to_json,
          headers: { "Content-Type" => "application/json" }
        )
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
        stub_request(:get, assistant_url)
          .to_return(
            status: 404,
            body: { error: "not_found" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
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
        stub_request(:get, assistant_url)
          .to_return(
            status: 200,
            body: { assistant_id: }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
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
        stub_request(:post, thread_init_url)
          .to_return(
            status: 409,
            body: { error: "Thread #{thread_id} already exists" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
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
        stub_request(:post, run_url)
          .with(body: run_request_body_without_context.to_json)
          .to_return(
            status: 200,
            body: run_response_body.to_json,
            headers: { "Content-Type" => "application/json" }
          )
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
        stub_request(:post, thread_init_url)
          .with(body: single_message_thread_init_body.to_json)
          .to_return(
            status: 200,
            body: {}.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        stub_request(:post, run_url)
          .with(body: single_message_run_body.to_json)
          .to_return(
            status: 200,
            body: run_response_body.to_json,
            headers: { "Content-Type" => "application/json" }
          )
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
        stub_request(:post, thread_init_url)
          .to_return(
            status: 500,
            body: { error: "Internal Server Error" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
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
        stub_request(:post, thread_state_url)
          .to_return(
            status: 500,
            body: { error: "Internal Server Error" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

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
        stub_request(:post, run_url)
          .to_return(
            status: 500,
            body: { error: "Internal Server Error" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises RunError" do
        expect do
          assistants.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(NitroIntelligence::Assistants::RunError, '{"error":"Internal Server Error"}')
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
        stub_request(:post, run_url)
          .with(body: run_request_body.to_json)
          .to_return(
            status: 200,
            body: multi_message_run_response_body.to_json,
            headers: { "Content-Type" => "application/json" }
          )
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
            stub_request(:post, thread_init_url)
              .to_return(
                status: status_code,
                body: {}.to_json,
                headers: { "Content-Type" => "application/json" }
              )
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
            stub_request(:post, run_url)
              .to_return(
                status: status_code,
                body: {}.to_json,
                headers: { "Content-Type" => "application/json" }
              )
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

  describe "#review_tool_calls" do
    let(:thread_id) { "thread-456" }
    let(:assistant_id) { "assistant-789" }
    let(:reviewer_id) { "reviewer-123" }
    let(:reviewed_at) { "2026-03-27T12:34:56Z" }
    let(:thread_url) { "#{base_url}/threads/#{thread_id}" }
    let(:state_url) { "#{base_url}/threads/#{thread_id}/state" }
    let(:run_url) { "#{base_url}/threads/#{thread_id}/runs/wait" }
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
            "arg_2" => "original value",
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
    let(:interrupt_context) do
      {
        "tool_calls" => %w[tool_call_id_1 tool_call_id_2],
      }
    end
    let(:review_actions) { %w[approve edit] }
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
          {
            "value" => {
              "context" => interrupt_context,
              "review_actions" => review_actions,
            },
          },
        ],
      }
    end
    let(:resume_payload) do
      {
        reviewer_id:,
        reviewed_at:,
        tool_calls:,
      }
    end
    let(:resume_request_body) do
      {
        assistant_id:,
        command: {
          resume: resume_payload,
        },
        context: interrupt_context,
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
      stub_request(:get, thread_url)
        .to_return(
          status: 200,
          body: thread.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, state_url)
        .to_return(
          status: 200,
          body: thread_state.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:post, run_url)
        .with(body: resume_request_body.to_json)
        .to_return(
          status: 200,
          body: run_response_body.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "fetches the thread and thread state before resuming reviewed tool calls" do
      assistants.review_tool_calls(
        thread_id:,
        assistant_id:,
        reviewer_id:,
        reviewed_at:,
        tool_calls:
      )

      expect(WebMock).to have_requested(:get, thread_url)
      expect(WebMock).to have_requested(:get, state_url).twice
    end

    it "passes the reviewed tool calls and interrupt context to wait-for-run" do
      assistants.review_tool_calls(
        thread_id:,
        assistant_id:,
        reviewer_id:,
        reviewed_at:,
        tool_calls:
      )

      expect(WebMock).to have_requested(:post, run_url)
        .with(body: resume_request_body.to_json)
    end

    it "returns nil" do
      result = assistants.review_tool_calls(
        thread_id:,
        assistant_id:,
        reviewer_id:,
        reviewed_at:,
        tool_calls:
      )

      expect(result).to be_nil
    end

    context "when reviewed_at is not provided" do
      let(:resume_request_body) do
        {
          assistant_id:,
          command: {
            resume: {
              reviewer_id:,
              reviewed_at: "2026-03-27T15:00:00+00:00",
              tool_calls:,
            },
          },
          context: interrupt_context,
        }
      end

      before do
        allow(DateTime).to receive(:current).and_return(DateTime.iso8601("2026-03-27T15:00:00Z"))
      end

      it "defaults reviewed_at to DateTime.current.iso8601" do
        assistants.review_tool_calls(
          thread_id:,
          assistant_id:,
          reviewer_id:,
          tool_calls:
        )

        expect(WebMock).to have_requested(:post, run_url)
          .with(body: resume_request_body.to_json)
      end
    end

    context "when the thread does not exist" do
      before do
        stub_request(:get, thread_url)
          .to_return(
            status: 404,
            body: {}.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ThreadResumptionError" do
        expect do
          assistants.review_tool_calls(
            thread_id:,
            assistant_id:,
            reviewer_id:,
            reviewed_at:,
            tool_calls:
          )
        end.to raise_error(NitroIntelligence::Assistants::ThreadResumptionError, "{}")
      end

      it "does not attempt to resume the thread" do
        expect do
          assistants.review_tool_calls(
            thread_id:,
            assistant_id:,
            reviewer_id:,
            reviewed_at:,
            tool_calls:
          )
        end.to raise_error(NitroIntelligence::Assistants::ThreadResumptionError)

        expect(WebMock).not_to have_requested(:get, state_url)
        expect(WebMock).not_to have_requested(:post, run_url)
      end
    end

    context "when the thread is no longer interrupted" do
      let(:thread_status) { "idle" }

      it "raises ThreadResumptionError" do
        expect do
          assistants.review_tool_calls(
            thread_id:,
            assistant_id:,
            reviewer_id:,
            reviewed_at:,
            tool_calls:
          )
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Thread #{thread_id} is not in the interrupted state"
        )
      end

      it "does not attempt to resume the thread" do
        expect do
          assistants.review_tool_calls(
            thread_id:,
            assistant_id:,
            reviewer_id:,
            reviewed_at:,
            tool_calls:
          )
        end.to raise_error(NitroIntelligence::Assistants::ThreadResumptionError)

        expect(WebMock).not_to have_requested(:get, state_url)
        expect(WebMock).not_to have_requested(:post, run_url)
      end
    end

    context "when the review includes a tool call that is not pending review" do
      let(:tool_calls) do
        super().merge(
          "tool_call_id_3" => {
            "action" => "approve",
          }
        )
      end

      it "raises ThreadResumptionError" do
        expect do
          assistants.review_tool_calls(
            thread_id:,
            assistant_id:,
            reviewer_id:,
            reviewed_at:,
            tool_calls:
          )
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Unknown tool call ids: tool_call_id_3"
        )
      end

      it "does not attempt to resume the thread" do
        expect do
          assistants.review_tool_calls(
            thread_id:,
            assistant_id:,
            reviewer_id:,
            reviewed_at:,
            tool_calls:
          )
        end.to raise_error(NitroIntelligence::Assistants::ThreadResumptionError)

        expect(WebMock).not_to have_requested(:post, run_url)
      end
    end

    context "when a review action is not allowed by the interrupt" do
      let(:review_actions) { ["approve"] }

      it "raises ThreadResumptionError" do
        expect do
          assistants.review_tool_calls(
            thread_id:,
            assistant_id:,
            reviewer_id:,
            reviewed_at:,
            tool_calls:
          )
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Invalid review action `edit` for tool call tool_call_id_2"
        )
      end

      it "does not attempt to resume the thread" do
        expect do
          assistants.review_tool_calls(
            thread_id:,
            assistant_id:,
            reviewer_id:,
            reviewed_at:,
            tool_calls:
          )
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
          assistants.review_tool_calls(
            thread_id:,
            assistant_id:,
            reviewer_id:,
            reviewed_at:,
            tool_calls:
          )
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Invalid edited args for tool call tool_call_id_2: arg_3"
        )
      end

      it "does not attempt to resume the thread" do
        expect do
          assistants.review_tool_calls(
            thread_id:,
            assistant_id:,
            reviewer_id:,
            reviewed_at:,
            tool_calls:
          )
        end.to raise_error(NitroIntelligence::Assistants::ThreadResumptionError)

        expect(WebMock).not_to have_requested(:post, run_url)
      end
    end

    context "when resuming the thread fails" do
      before do
        stub_request(:post, run_url)
          .with(body: resume_request_body.to_json)
          .to_return(
            status: 500,
            body: { error: "Internal Server Error" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ThreadResumptionError" do
        expect do
          assistants.review_tool_calls(
            thread_id:,
            assistant_id:,
            reviewer_id:,
            reviewed_at:,
            tool_calls:
          )
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          '{"error":"Internal Server Error"}'
        )
      end
    end
  end

  describe "#thread_state" do
    let(:thread_id) { "thread-456" }
    let(:state_url) { "#{base_url}/threads/#{thread_id}/state" }
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
        stub_request(:get, state_url)
          .to_return(
            status: 200,
            body: thread_state.to_json,
            headers: { "Content-Type" => "application/json" }
          )
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
        stub_request(:get, state_url)
          .to_return(
            status: 404,
            body: { "detail" => "Thread not found" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
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
    let(:thread_id) { "thread-456" }
    let(:state_url) { "#{base_url}/threads/#{thread_id}/state" }
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
      stub_request(:get, state_url)
        .to_return(
          status: 200,
          body: thread_state.to_json,
          headers: { "Content-Type" => "application/json" }
        )
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
    let(:thread_id) { "thread-456" }
    let(:state_url) { "#{base_url}/threads/#{thread_id}/state" }
    let(:thread_state) do
      {
        "values" => {
          "messages" => messages,
        },
      }
    end

    before do
      stub_request(:get, state_url)
        .to_return(
          status: 200,
          body: thread_state.to_json,
          headers: { "Content-Type" => "application/json" }
        )
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
end
