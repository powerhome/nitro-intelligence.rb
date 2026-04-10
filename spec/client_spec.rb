require "spec_helper"
# Assuming this is the path to the module definition
require "nitro_intelligence/client/factory"

RSpec.describe NitroIntelligence::Client do
  describe ".new" do
    it "delegates client creation to the Factory" do
      fake_factory = instance_double(NitroIntelligence::Client::Factory)

      expect(NitroIntelligence::Client::Factory).to receive(:new)
        .with(observability_project_slug: "test-slug")
        .and_return(fake_factory)

      expect(fake_factory).to receive(:build).and_return("fake-built-client")

      result = described_class.new(observability_project_slug: "test-slug")

      expect(result).to eq("fake-built-client")
    end

    it "handles initialization without a project slug" do
      fake_factory = instance_double(NitroIntelligence::Client::Factory)

      expect(NitroIntelligence::Client::Factory).to receive(:new)
        .with(observability_project_slug: nil)
        .and_return(fake_factory)

      expect(fake_factory).to receive(:build)

      described_class.new
    end
  end
end
