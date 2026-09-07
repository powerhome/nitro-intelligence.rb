require "spec_helper"

RSpec.describe NitroIntelligence::Configuration do
  describe "defaults" do
    it "points the inference base url at the inference gateway" do
      expect(described_class.config.inference_base_url).to eq("https://inference.powerhome.ai")
    end
  end
end
