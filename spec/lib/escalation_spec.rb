require "spec_helper"
require "nitro_intelligence/assistants"

RSpec.describe NitroIntelligence::Escalation do
  subject(:escalation) { described_class.new(block) }

  # As a run's output carries it (docs/escalation.md in nip-assistants).
  let(:block) do
    {
      "outcome" => "escalated",
      "id" => "esc-7f3a91c2d4e5",
      "status" => "open",
      "source" => "judge",
      "reason" => "asked_for_person",
      "details" => "The customer asked for a person.",
      "message_id" => "msg-4",
      "tool_call_id" => "escalation-0c9d2e7f1a3b",
      "at" => "2026-11-12T14:03:00Z",
      "judge" => { "verdict" => "escalate", "reason" => "asked_for_person", "confidence" => 0.84 },
      "delivery" => {
        "status" => "delivered", "tool" => "hand_to_agent", "attempts" => 1,
        "delivered_at" => "2026-11-12T14:03:01Z", "result" => "Queued"
      },
    }
  end

  it "reads the run output's escalation" do
    expect(escalation).to have_attributes(
      id: "esc-7f3a91c2d4e5", status: "open", source: "judge", reason: "asked_for_person",
      details: "The customer asked for a person.", message_id: "msg-4",
      tool_call_id: "escalation-0c9d2e7f1a3b", at: "2026-11-12T14:03:00Z",
      judge: { "verdict" => "escalate", "reason" => "asked_for_person", "confidence" => 0.84 },
      resolved_by: nil, resolved_at: nil
    )
    expect(escalation).to be_open
    expect(escalation).not_to be_handed_back
    expect(escalation).not_to be_closed
    expect(escalation).not_to be_sandbox
  end

  it "reads the delivery as a reply's delivery is read" do
    expect(escalation.delivery).to be_a(NitroIntelligence::RunResult::Delivery)
    expect(escalation.delivery).to be_delivered
    expect(escalation.delivery).to have_attributes(tool: "hand_to_agent", attempts: 1, result: "Queued",
                                                   delivered_at: "2026-11-12T14:03:01Z")
  end

  it "keeps the response as given" do
    expect(escalation.raw).to eq(block)
  end

  context "with a resolution's summary" do
    let(:block) do
      {
        id: "esc-1", status: "handed_back", source: "model", reason: "Wants a person.",
        at: "2026-11-12T14:03:00Z", delivery: { status: "failed" },
        resolved_by: "jane@example.com", resolved_at: "2026-11-12T15:10:00Z"
      }
    end

    it "reads what the summary carries, with string or symbol keys" do
      expect(escalation).to have_attributes(id: "esc-1", resolved_by: "jane@example.com",
                                            resolved_at: "2026-11-12T15:10:00Z", details: nil, judge: nil)
      expect(escalation).to be_handed_back
      expect(escalation.delivery).to be_failed
      expect(escalation.delivery.tool).to be_nil
    end
  end

  context "with fields of the wrong type" do
    let(:block) { { "id" => 7, "judge" => "escalate", "delivery" => "delivered", "sandbox" => "true" } }

    it "reads them as nil" do
      expect(escalation).to have_attributes(id: nil, judge: nil, delivery: nil)
      expect(escalation).not_to be_sandbox
    end
  end

  context "when a sandbox run escalated" do
    let(:block) { { "id" => "esc-1", "status" => "closed", "sandbox" => true } }

    it { is_expected.to be_sandbox }
    it { is_expected.to be_closed }
  end

  describe ".from" do
    it "builds one from a Hash" do
      expect(described_class.from({ "id" => "esc-1" }).id).to eq("esc-1")
    end

    it "is nil for anything else" do
      expect(described_class.from(nil)).to be_nil
      expect(described_class.from("esc-1")).to be_nil
    end
  end
end
