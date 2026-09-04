require "spec_helper"

RSpec.describe NitroIntelligence do
  describe ".assistants" do
    around do |example|
      original = described_class.config.assistants_config
      example.run
      described_class.config.assistants_config = original
    end

    context "when the configuration carries definitions" do
      before do
        described_class.config.assistants_config = {
          "base_url" => "https://nip.example.com",
          "definitions" => { "candidate-concierge" => {} },
        }
      end

      it "returns a registry addressable by name" do
        expect(described_class.assistants).to be_a(NitroIntelligence::AssistantRegistry)
        expect(described_class.assistants.keys).to eq(["candidate-concierge"])
      end
    end

    # A host that has not reshaped its configuration keeps the client it already had.
    context "when the configuration is the single-client shape" do
      before do
        described_class.config.assistants_config = {
          "base_url" => "https://nip.example.com",
          "api_key" => "key",
        }
      end

      it "returns the client" do
        expect(described_class.assistants).to be_a(NitroIntelligence::Assistants)
      end
    end
  end
end
