require "spec_helper"
require "nitro_intelligence/agent_server"
require "webmock/rspec"

RSpec.describe NitroIntelligence do
  describe ".agent_server" do
    let(:base_url) { "https://agent-server.example.com" }
    let(:api_key) { "test-api-key" }

    before do
      NitroIntelligence.configuration.agent_server_config = {
        "base_url" => base_url,
        "api_key" => api_key,
      }
    end

    after do
      NitroIntelligence.configuration.agent_server_config = {}
    end

    it "returns an instance of AgentServer" do
      expect(described_class.agent_server).to be_a(NitroIntelligence::AgentServer)
    end

    it "configures the AgentServer with agent_server_config" do
      agent_server = described_class.agent_server

      expect(agent_server.base_url).to eq(base_url)
    end

    it "returns a new instance on each call" do
      first_instance = described_class.agent_server
      second_instance = described_class.agent_server

      expect(first_instance).not_to be(second_instance)
    end

    context "with custom user_id in config" do
      before do
        NitroIntelligence.configuration.agent_server_config = {
          "base_url" => base_url,
          "api_key" => api_key,
          "user_id" => "custom-user",
        }
      end

      it "uses the configured user_id" do
        expect(described_class.agent_server.user_id).to eq("custom-user")
      end
    end

    context "without user_id in config" do
      it "uses the default user_id" do
        expect(described_class.agent_server.user_id).to eq("default-user")
      end
    end
  end
end

RSpec.describe NitroIntelligence::AgentServer do
  let(:base_url) { "https://agent-server.example.com" }
  let(:api_key) { "test-api-key" }
  let(:user_id) { "user-123" }
  let(:agent_server) { described_class.new(base_url:, api_key:, user_id:) }

  describe "#initialize" do
    context "with valid parameters" do
      it "creates an instance with the provided base_url" do
        expect(agent_server.base_url).to eq(base_url)
      end

      it "creates an instance with the provided user_id" do
        expect(agent_server.user_id).to eq(user_id)
      end
    end

    context "with default user_id" do
      let(:agent_server_with_default_user) { described_class.new(base_url:, api_key:) }

      it "defaults user_id to 'default-user'" do
        expect(agent_server_with_default_user.user_id).to eq("default-user")
      end
    end

    context "with missing base_url" do
      it "raises ConfigurationError when base_url is nil" do
        expect do
          described_class.new(base_url: nil, api_key:, user_id:)
        end.to raise_error(NitroIntelligence::AgentServer::ConfigurationError, "base_url is required")
      end

      it "raises ConfigurationError when base_url is empty" do
        expect do
          described_class.new(base_url: "", api_key:, user_id:)
        end.to raise_error(NitroIntelligence::AgentServer::ConfigurationError, "base_url is required")
      end
    end

    context "with missing api_key" do
      it "raises ConfigurationError when api_key is nil" do
        expect do
          described_class.new(base_url:, api_key: nil, user_id:)
        end.to raise_error(NitroIntelligence::AgentServer::ConfigurationError, "api_key is required")
      end

      it "raises ConfigurationError when api_key is empty" do
        expect do
          described_class.new(base_url:, api_key: "", user_id:)
        end.to raise_error(NitroIntelligence::AgentServer::ConfigurationError, "api_key is required")
      end
    end

    context "with missing user_id" do
      it "raises ConfigurationError when user_id is nil" do
        expect do
          described_class.new(base_url:, api_key:, user_id: nil)
        end.to raise_error(NitroIntelligence::AgentServer::ConfigurationError, "user_id is required")
      end

      it "raises ConfigurationError when user_id is empty" do
        expect do
          described_class.new(base_url:, api_key:, user_id: "")
        end.to raise_error(NitroIntelligence::AgentServer::ConfigurationError, "user_id is required")
      end
    end
  end

  describe "#await_run" do
    let(:thread_id) { "thread-456" }
    let(:assistant_id) { "assistant-789" }
    let(:context) { { key: "value" } }
    let(:thread_init_url) { "#{base_url}/threads" }
    let(:run_url) { "#{base_url}/threads/#{thread_id}/runs/wait" }

    context "when messages is nil" do
      it "raises RunError" do
        expect do
          agent_server.await_run(thread_id:, assistant_id:, messages: nil, context:)
        end.to raise_error(NitroIntelligence::AgentServer::RunError, "messages cannot be empty")
      end

      it "does not attempt to initialize the thread" do
        expect do
          agent_server.await_run(thread_id:, assistant_id:, messages: nil, context:)
        end.to raise_error(NitroIntelligence::AgentServer::RunError)

        expect(WebMock).not_to have_requested(:post, thread_init_url)
      end
    end

    context "when messages is empty" do
      it "raises RunError" do
        expect do
          agent_server.await_run(thread_id:, assistant_id:, messages: [], context:)
        end.to raise_error(NitroIntelligence::AgentServer::RunError, "messages cannot be empty")
      end

      it "does not attempt to initialize the thread" do
        expect do
          agent_server.await_run(thread_id:, assistant_id:, messages: [], context:)
        end.to raise_error(NitroIntelligence::AgentServer::RunError)

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
        ifExists: "do_nothing",
        initial_state: { messages: messages[0..-2] },
        user_id:,
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
      stub_request(:post, thread_init_url)
        .with(body: thread_init_request_body.to_json)
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

    it "initializes the thread with initial state (all messages except the last)" do
      agent_server.await_run(thread_id:, assistant_id:, messages:, context:)

      expect(WebMock).to have_requested(:post, thread_init_url)
        .with(body: thread_init_request_body.to_json)
    end

    it "triggers a run with the last message" do
      agent_server.await_run(thread_id:, assistant_id:, messages:, context:)

      expect(WebMock).to have_requested(:post, run_url)
        .with(body: run_request_body.to_json)
    end

    it "returns the content of the last message from the run response" do
      result = agent_server.await_run(thread_id:, assistant_id:, messages:, context:)

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
        agent_server.await_run(thread_id:, assistant_id:, messages:)

        expect(WebMock).to have_requested(:post, run_url)
          .with(body: run_request_body_without_context.to_json)
      end
    end

    context "when there is only one message" do
      let(:single_message) { [{ role: "user", content: "Hello" }] }

      let(:single_message_thread_init_body) do
        {
          threadId: thread_id.to_s,
          ifExists: "do_nothing",
          initial_state: { messages: [] },
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

      it "initializes thread with empty initial state" do
        agent_server.await_run(thread_id:, assistant_id:, messages: single_message, context:)

        expect(WebMock).to have_requested(:post, thread_init_url)
          .with(body: single_message_thread_init_body.to_json)
      end

      it "triggers run with the single message" do
        agent_server.await_run(thread_id:, assistant_id:, messages: single_message, context:)

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
          agent_server.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(NitroIntelligence::AgentServer::ThreadInitializationError, '{"error":"Internal Server Error"}')
      end

      it "does not attempt to trigger the run" do
        expect do
          agent_server.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(NitroIntelligence::AgentServer::ThreadInitializationError)

        expect(WebMock).not_to have_requested(:post, run_url)
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
          agent_server.await_run(thread_id:, assistant_id:, messages:, context:)
        end.to raise_error(NitroIntelligence::AgentServer::RunError, '{"error":"Internal Server Error"}')
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
        result = agent_server.await_run(thread_id:, assistant_id:, messages:, context:)

        expect(result).to eq("Final response")
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
              agent_server.await_run(thread_id:, assistant_id:, messages:, context:)
            end.to raise_error(NitroIntelligence::AgentServer::ThreadInitializationError)
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
              agent_server.await_run(thread_id:, assistant_id:, messages:, context:)
            end.to raise_error(NitroIntelligence::AgentServer::RunError)
          end
        end
      end
    end
  end
end
