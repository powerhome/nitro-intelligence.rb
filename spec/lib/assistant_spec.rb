require "spec_helper"
require "nitro_intelligence/assistant"

RSpec.describe NitroIntelligence::Assistant do
  subject(:assistant) { described_class.new(key, **attributes) }

  let(:key) { "candidate-concierge" }

  let(:attributes) do
    {
      base_url: "https://nip.example.com",
      api_key: "key-cc",
      assistant_id: "id-cc",
    }
  end

  it "exposes what the host supplied" do
    expect(assistant.key).to eq("candidate-concierge")
    expect(assistant.assistant_id).to eq("id-cc")
    expect(assistant.base_url).to eq("https://nip.example.com")
  end

  it "defaults the user id" do
    expect(assistant.user_id).to eq(described_class::DEFAULT_USER_ID)
  end

  context "when a user id is supplied" do
    let(:attributes) { super().merge(user_id: "nitro-web") }

    it "uses it" do
      expect(assistant.user_id).to eq("nitro-web")
    end
  end

  describe "validation" do
    it "names every missing credential at once" do
      expect { described_class.new("candidate-concierge") }
        .to raise_error(described_class::ConfigurationError,
                        /"candidate-concierge" is missing base_url, api_key, assistant_id/)
    end

    it "names only what is missing" do
      expect { described_class.new(key, **attributes.except(:assistant_id)) }
        .to raise_error(described_class::ConfigurationError, /is missing assistant_id\z/)
    end

    it "treats a blank value as missing" do
      expect { described_class.new(key, **attributes, api_key: "  ") }
        .to raise_error(described_class::ConfigurationError, /is missing api_key/)
    end
  end

  describe "extra keys" do
    let(:attributes) { super().merge(graph_id: "react-agent", cerebro_project_slug: "cc") }

    it "ignores fields the application has no use for" do
      expect(assistant.assistant_id).to eq("id-cc")
    end

    # A host sharing one structure with its deployment carries a human-readable label of its
    # own. As a keyword it would silently win over the key the assistant is looked up by.
    context "when an entry carries a name of its own" do
      let(:attributes) { super().merge(name: "Candidate Concierge") }

      it "keeps the key it was constructed with" do
        expect(assistant.key).to eq("candidate-concierge")
      end
    end
  end

  describe "the client" do
    it "is built from the assistant's own settings" do
      expect(assistant.client.base_url).to eq("https://nip.example.com")
    end

    it "is memoized" do
      expect(assistant.client).to equal(assistant.client)
    end
  end

  describe "delegation" do
    let(:client) { instance_double(NitroIntelligence::Assistants) }

    before { allow(NitroIntelligence::Assistants).to receive(:new).and_return(client) }

    it "supplies the assistant id to a run" do
      expect(client).to receive(:await_run)
        .with(thread_id: "t1", assistant_id: "id-cc", messages: ["hi"], context: { a: 1 })

      assistant.await_run(thread_id: "t1", messages: ["hi"], context: { a: 1 })
    end

    it "supplies the assistant id to a tool call review" do
      expect(client).to receive(:review_tool_calls)
        .with(thread_id: "t1", assistant_id: "id-cc", reviewer_id: "r1", tool_calls: [])

      assistant.review_tool_calls(thread_id: "t1", reviewer_id: "r1", tool_calls: [])
    end

    it "passes thread-scoped calls straight through" do
      expect(client).to receive(:thread_state).with(thread_id: "t1")

      assistant.thread_state(thread_id: "t1")
    end
  end
end
