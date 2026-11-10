require "spec_helper"
require "timeout"

RSpec.describe NitroIntelligence do
  describe ".project_client_registry" do
    around do |example|
      original = described_class.instance_variable_get(:@project_client_registry)
      described_class.instance_variable_set(:@project_client_registry, nil)
      example.run
    ensure
      described_class.instance_variable_set(:@project_client_registry, original)
    end

    it "shares one registry between concurrent first-time calls" do
      building = Queue.new
      release = Queue.new
      registry_class = NitroIntelligence::Observability::ProjectClientRegistry
      allow(registry_class).to receive(:new).and_wrap_original do |original, **kwargs|
        building << true
        release.pop
        original.call(**kwargs)
      end
      first = Thread.new { described_class.project_client_registry }
      expect(building.pop(timeout: 5)).to be(true)
      second = Thread.new { described_class.project_client_registry }
      # Wait until the second call reaches the lock or attempts another construction.
      Timeout.timeout(5) { Thread.pass until second.status == "sleep" }
      release.close

      registry = first.join(5)&.value
      expect(registry).to be_a(registry_class)
      expect(second.join(5)&.value).to equal(registry)
      expect(described_class.project_client_registry).to equal(registry)
      expect(registry_class).to have_received(:new).once
    ensure
      release&.close
      first&.join(5)
      second&.join(5)
    end
  end

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
