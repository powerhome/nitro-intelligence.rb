require "spec_helper"
require "nitro_intelligence/assistant_registry"

RSpec.describe NitroIntelligence::AssistantRegistry do
  subject(:registry) { described_class.new(config) }

  let(:config) do
    {
      "base_url" => "https://nip.example.com",
      "user_id" => "nitro-web",
      "definitions" => {
        "candidate-concierge" => {
          "graph_id" => "react-agent", "cerebro_project_slug" => "cc",
          "name" => "Candidate Concierge",
          "api_key" => "key-cc", "assistant_id" => "id-cc"
        },
        "home-studio" => {
          "base_url" => "https://pr306.nip.example.com",
          "api_key" => "key-hs", "assistant_id" => "id-hs"
        },
      },
    }
  end

  describe "#[]" do
    it "resolves an assistant by name" do
      assistant = registry["candidate-concierge"]

      expect(assistant.key).to eq("candidate-concierge")
      expect(assistant.assistant_id).to eq("id-cc")
    end

    # The fixture entry carries a `name` of its own, as a host sharing one structure with its
    # deployment would. The key it is filed under has to win.
    it "is not renamed by a name on the entry" do
      expect(registry["candidate-concierge"].key).to eq("candidate-concierge")
    end

    it "applies the shared connection settings" do
      assistant = registry["candidate-concierge"]

      expect(assistant.base_url).to eq("https://nip.example.com")
      expect(assistant.user_id).to eq("nitro-web")
    end

    # A review environment points one assistant elsewhere while the rest stay on the shared host.
    it "lets a definition override a shared setting" do
      expect(registry["home-studio"].base_url).to eq("https://pr306.nip.example.com")
    end

    it "inherits the settings a definition does not override" do
      expect(registry["home-studio"].user_id).to eq("nitro-web")
    end

    it "memoizes the resolved assistant" do
      expect(registry["candidate-concierge"]).to equal(registry["candidate-concierge"])
    end

    it "accepts a symbol" do
      expect(registry[:"candidate-concierge"].assistant_id).to eq("id-cc")
    end

    it "names the configured assistants when one is unknown" do
      expect { registry["nope"] }
        .to raise_error(described_class::UnknownAssistantError, /candidate-concierge, home-studio/)
    end
  end

  describe "#keys and #key?" do
    it "lists the configured assistants" do
      expect(registry.keys).to contain_exactly("candidate-concierge", "home-studio")
    end

    it "reports whether an assistant is configured" do
      expect(registry.key?("candidate-concierge")).to be(true)
      expect(registry.key?("nope")).to be(false)
    end
  end

  context "with no configuration at all" do
    let(:config) { {} }

    it "has no assistants" do
      expect(registry.keys).to be_empty
    end

    it "still explains an unknown lookup" do
      expect { registry["candidate-concierge"] }
        .to raise_error(described_class::UnknownAssistantError, /\(none\)/)
    end
  end
end
