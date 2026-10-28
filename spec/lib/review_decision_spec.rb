require "spec_helper"
require "nitro_intelligence/review_decision"

RSpec.describe NitroIntelligence::ReviewDecision do
  describe ".reject" do
    it "carries a reason only when one is given" do
      expect(described_class.reject(nil)).to eq("type" => "reject")
      expect(described_class.reject("No")).to eq("type" => "reject", "message" => "No")
    end
  end

  describe ".message_problem" do
    it "reports a required message that is absent or blank as missing" do
      expect(described_class.message_problem(nil, required: true)).to eq(:missing)
      expect(described_class.message_problem(" ", required: true)).to eq(:missing)
    end

    it "reports a message that is not a string, required or not" do
      expect(described_class.message_problem(1, required: true)).to eq(:not_string)
      expect(described_class.message_problem(1, required: false)).to eq(:not_string)
    end

    it "accepts an absent or blank optional message, and any required text" do
      expect(described_class.message_problem(nil, required: false)).to be_nil
      expect(described_class.message_problem("", required: false)).to be_nil
      expect(described_class.message_problem("Hi", required: true)).to be_nil
    end
  end
end
