require "spec_helper"

RSpec.describe NitroIntelligence::Configuration do
  describe "defaults" do
    it "points the inference base url at Assistants" do
      expect(described_class.config.inference_base_url).to eq("https://assistants.powerhome.ai")
    end

    it "points the observability base url at Cerebro" do
      expect(described_class.config.observability_base_url).to eq("https://cerebro.powerhome.ai")
    end
  end
end
