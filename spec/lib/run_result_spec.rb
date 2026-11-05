require "spec_helper"
require "nitro_intelligence/assistants"

RSpec.describe NitroIntelligence::RunResult do
  subject(:result) { described_class.new(run) }

  let(:human) { { "type" => "human", "id" => "human-1", "content" => "Can I move my appointment?" } }
  let(:draft) { { "type" => "ai", "id" => "ai-2", "content" => "Sure! You're booked for Tuesday at 10am." } }
  let(:tool_turn) do
    {
      "type" => "ai", "id" => "ai-1", "content" => "Let me check that for you.",
      "tool_calls" => [{ "id" => "call-1", "name" => "lookup_appointment", "args" => {} }]
    }
  end
  let(:tool_result) { { "type" => "tool", "id" => "tool-1", "tool_call_id" => "call-1", "content" => "Tuesday 10am" } }

  context "when the run ended with a reply" do
    let(:run) { { "messages" => [human, tool_turn, tool_result, draft] } }

    it "returns the reply" do
      expect(result).not_to be_interrupted
      expect(result.reply).to eq("Sure! You're booked for Tuesday at 10am.")
      expect(result.review).to be_nil
    end
  end

  context "when the run paused on the reply" do
    let(:run) { { "messages" => [human, draft], "__interrupt__" => [reply_interrupt_for(draft["content"])] } }

    it "holds the draft back from the reply" do
      expect(result).to be_interrupted
      expect(result.reply).to be_nil
      expect(result.delivery).to be_nil
      expect(result.review.reply.content).to eq("Sure! You're booked for Tuesday at 10am.")
    end
  end

  context "when the run paused on the reply, which the platform stamped as awaiting review" do
    let(:pending_draft) { draft.merge("response_metadata" => { "review" => { "type" => "pending" } }) }
    let(:run) { { "messages" => [human, pending_draft], "__interrupt__" => [reply_interrupt_for(draft["content"])] } }

    it "reads the pause as it does without the stamp" do
      expect(result.reply).to be_nil
      expect(result.review.reply.content).to eq("Sure! You're booked for Tuesday at 10am.")
      expect(result.review.reply.allowed_decisions).to eq(%w[approve edit reject])
    end
  end

  context "when a draft stamped as awaiting review comes back without a pause" do
    let(:run) { { "messages" => [human, draft.merge("response_metadata" => { "review" => { "type" => "pending" } })] } }

    it "has no reply, since nobody has reviewed it" do
      expect(result.reply).to be_nil
      expect(result.delivery).to be_nil
    end
  end

  context "when the reply was reviewed" do
    let(:reviewed) do
      draft.merge("response_metadata" => { "review" => { "type" => "approve", "reviewer_id" => "jane" } })
    end
    let(:run) { { "messages" => [human, reviewed] } }

    it "returns it" do
      expect(result.reply).to eq("Sure! You're booked for Tuesday at 10am.")
    end
  end

  context "when the run paused on tool calls" do
    let(:run) do
      { "messages" => [human, tool_turn], "__interrupt__" => [tool_interrupt_for("lookup_appointment", {})] }
    end

    it "has no reply, and never the tool turn's working text" do
      expect(result.reply).to be_nil
      expect(result.review.tool_calls.map { |tool_call| tool_call["id"] }).to eq(["call-1"])
    end
  end

  context "when a rejected draft left the tool result of an earlier turn last" do
    let(:run) { { "messages" => [human, tool_turn, tool_result] } }

    it "has no reply, rather than the earlier turn's text" do
      expect(result.reply).to be_nil
      expect(result.delivery).to be_nil
    end
  end

  context "when a rejected draft left the human's message last" do
    let(:run) { { "messages" => [human] } }

    it "has no reply" do
      expect(result.reply).to be_nil
    end
  end

  context "when the last message calls tools" do
    let(:run) { { "messages" => [human, tool_turn] } }

    it "has no reply, though the message has text" do
      expect(result.reply).to be_nil
    end
  end

  context "when the run reports no messages" do
    let(:run) { { "messages" => nil } }

    it "has no reply" do
      expect(result.reply).to be_nil
      expect(result.messages).to eq([])
    end
  end

  context "when the reply's content is a list of blocks" do
    let(:blocks) do
      [
        { "type" => "reasoning", "reasoning" => "The customer wants Tuesday." },
        { "type" => "text", "text" => "Sure! " },
        "Tuesday at 10am works.",
        { "type" => "tool_use", "id" => "c", "name" => "noop", "input" => {} },
      ]
    end
    let(:run) { { "messages" => [human, draft.merge("content" => blocks)] } }

    it "returns its text blocks joined, as a string" do
      expect(result.reply).to eq("Sure! Tuesday at 10am works.")
    end
  end

  context "when the reply's blocks carry no text" do
    let(:run) { { "messages" => [human, draft.merge("content" => [{ "type" => "tool_use", "id" => "c" }])] } }

    it "has no reply" do
      expect(result.reply).to be_nil
    end
  end

  context "when the reply is blank" do
    let(:run) { { "messages" => [human, draft.merge("content" => "  \n")] } }

    it "has no reply" do
      expect(result.reply).to be_nil
    end
  end

  describe "#delivery" do
    let(:run) { { "messages" => [human, draft.merge("response_metadata" => { "delivery" => stamp })] } }

    context "when the reply was delivered" do
      let(:stamp) do
        {
          "status" => "delivered", "tool" => "send_sms", "attempts" => 1,
          "delivered_at" => "2026-10-18T14:03:01Z", "result" => { "provider_message_id" => "SM8f2c" }
        }
      end

      it "reports it, with the tool's result" do
        expect(result.delivery).to be_delivered
        expect(result.delivery).to have_attributes(
          status: "delivered", tool: "send_sms", attempts: 1, error: nil,
          result: { "provider_message_id" => "SM8f2c" }, delivered_at: "2026-10-18T14:03:01Z"
        )
      end
    end

    context "when every attempt failed" do
      let(:stamp) do
        {
          "status" => "failed", "tool" => "send_sms", "attempts" => 3, "error" => "Number opted out",
          "failed_at" => "2026-10-18T14:03:09Z"
        }
      end

      it "reports the failure, the tool's error and when it failed" do
        expect(result.delivery).to be_failed
        expect(result.delivery).to have_attributes(
          status: "failed", attempts: 3, error: "Number opted out", result: nil,
          failed_at: "2026-10-18T14:03:09Z", delivered_at: nil
        )
      end
    end

    context "when delivery was cut off before it recorded an outcome" do
      let(:stamp) { { "status" => "pending", "tool" => "send_sms" } }

      it "reports it as pending, neither delivered nor failed" do
        expect(result.reply).to eq("Sure! You're booked for Tuesday at 10am.")
        expect(result.delivery).to be_pending
        expect(result.delivery).not_to be_delivered
        expect(result.delivery).not_to be_failed
      end
    end

    context "when the stamp carries fields of the wrong type" do
      let(:stamp) { { "status" => "failed", "attempts" => "3", "error" => { "code" => 1 } } }

      it "leaves them out" do
        expect(result.delivery).to have_attributes(status: "failed", attempts: nil, error: nil)
      end
    end

    context "when the reply carries no delivery stamp" do
      let(:run) { { "messages" => [human, draft.merge("response_metadata" => { "review" => { "type" => "approve" } })] } }

      it "is nil" do
        expect(result.delivery).to be_nil
      end
    end
  end

  it "keeps the raw response" do
    expect(described_class.new("messages" => []).raw).to eq("messages" => [])
  end
end
