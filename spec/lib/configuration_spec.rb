require "spec_helper"

RSpec.describe NitroIntelligence::Configuration do
  describe "defaults" do
    it "points the inference base url at the shared gateway" do
      expect(described_class.config.inference_base_url).to eq("https://nip-assistants.powerapp.cloud")
    end
  end
end
