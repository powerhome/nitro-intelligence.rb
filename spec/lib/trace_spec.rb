require "spec_helper"
require "nitro_intelligence/trace"

RSpec.describe NitroIntelligence::Trace do
  describe ".create_id" do
    it "creates a deterministic ID from a given seed" do
      id1 = NitroIntelligence::Trace.create_id(seed: "test-seed")
      id2 = NitroIntelligence::Trace.create_id(seed: "test-seed")

      expect(id1).to eq(id2)
    end

    it "creates IDs with length of 32 characters by default" do
      id = NitroIntelligence::Trace.create_id(seed: "test-seed")

      expect(id.length).to eq(32)
    end

    it "allows overriding the ID length" do
      id = NitroIntelligence::Trace.create_id(seed: "test-seed", length: 16)

      expect(id.length).to eq(16)
    end
  end
end
