require "spec_helper"
require "nitro_intelligence/assistants"

RSpec.describe NitroIntelligence::PendingReview do
  subject(:pending_review) { described_class.new(interrupt:, messages:) }

  let(:messages) do
    [
      { "type" => "human", "id" => "human-1", "content" => "Can I move my appointment?" },
      { "type" => "ai", "id" => "ai-1", "content" => "Sure! You're booked for Tuesday at 10am." },
    ]
  end
  let(:reply_allowed_decisions) { %w[approve edit reject] }
  let(:reply_interrupt) do
    {
      "id" => "interrupt-reply",
      "value" => {
        "action_requests" => [
          {
            "name" => "__reply__",
            "args" => { "content" => "Sure! You're booked for Tuesday at 10am." },
            "description" => "Review this SMS",
          },
        ],
        "review_configs" => [
          { "action_name" => "__reply__", "allowed_decisions" => reply_allowed_decisions },
        ],
      },
    }
  end
  let(:delivery_interrupt) do
    {
      "id" => "interrupt-delivery",
      "value" => {
        "action_requests" => [
          {
            "name" => "__delivery__",
            "args" => {
              "content" => "Great, see you Thursday at 9am!",
              "message_id" => "ai-1",
              "error" => "Quiet hours: messages can't be sent before 8am",
              "attempts" => 3,
            },
            "description" => "This reply couldn't be delivered.",
          },
        ],
        "review_configs" => [
          { "action_name" => "__delivery__", "allowed_decisions" => %w[approve edit reject] },
        ],
      },
    }
  end
  let(:interrupt) { reply_interrupt }

  def resumption_error
    NitroIntelligence::Assistants::ThreadResumptionError
  end

  describe ".from_thread_state" do
    it "reads the first of the thread's interrupts" do
      review = described_class.from_thread_state(
        "values" => { "messages" => messages }, "interrupts" => [reply_interrupt]
      )

      expect(review.interrupt_id).to eq("interrupt-reply")
    end

    it "is nil when the thread is not paused" do
      expect(described_class.from_thread_state("values" => { "messages" => messages }, "interrupts" => [])).to be_nil
    end
  end

  describe ".from_run" do
    it "reads the run's __interrupt__" do
      review = described_class.from_run("messages" => messages, "__interrupt__" => [delivery_interrupt])

      expect(review).to be_delivery
    end

    it "is nil when the run did not pause" do
      expect(described_class.from_run("messages" => messages)).to be_nil
    end
  end

  context "when the pause is on a reply" do
    it "exposes the draft with what a reviewer may do with it" do
      expect(pending_review.kind).to eq(:reply)
      expect(pending_review.reply).to have_attributes(
        content: "Sure! You're booked for Tuesday at 10am.",
        allowed_decisions: %w[approve edit reject],
        description: "Review this SMS",
        interrupt_id: "interrupt-reply"
      )
    end

    it "holds no tool calls and no delivery" do
      expect(pending_review.tool_calls).to eq([])
      expect(pending_review.delivery).to be_nil
    end

    it "approves" do
      expect(pending_review.decisions("action" => "approve")).to eq([{ "type" => "approve" }])
    end

    it "edits the reply's content" do
      expect(pending_review.decisions("action" => "edit", "content" => "Tuesday at 10am works.")).to eq(
        [{ "type" => "edit", "edited_action" => { "name" => "__reply__", "args" => { "content" => "Tuesday at 10am works." } } }]
      )
    end

    it "rejects with a reason" do
      expect(pending_review.decisions(action: "reject", message: "Wrong appointment")).to eq(
        [{ "type" => "reject", "message" => "Wrong appointment" }]
      )
    end

    it "rejects without a reason" do
      expect(pending_review.decisions("action" => "reject")).to eq([{ "type" => "reject" }])
    end

    context "when respond is allowed" do
      let(:reply_allowed_decisions) { %w[approve respond] }

      it "replaces the reply with the reviewer's message" do
        expect(pending_review.decisions("action" => "respond", "message" => "I'll call you.")).to eq(
          [{ "type" => "respond", "message" => "I'll call you." }]
        )
      end

      it "refuses a respond without a message" do
        expect { pending_review.decisions("action" => "respond") }
          .to raise_error(resumption_error, /`respond` review of the reply must include a non-empty `message`/)
      end
    end

    it "refuses a decision the interrupt does not allow" do
      expect { pending_review.decisions("action" => "respond", "message" => "Hi") }
        .to raise_error(resumption_error, "Invalid review action `respond` for the reply; allowed: approve, edit, reject")
    end

    it "refuses an edit without content" do
      expect { pending_review.decisions("action" => "edit", "content" => " ") }
        .to raise_error(resumption_error, /`edit` review of the reply must include a non-empty `content`/)
    end

    it "refuses a reason that is not a string" do
      expect { pending_review.decisions("action" => "reject", "message" => 1) }
        .to raise_error(resumption_error, /`message` for the reply review must be a string/)
    end

    it "refuses a review that is not a hash" do
      expect { pending_review.decisions("approve") }
        .to raise_error(resumption_error, "The reply review must be a hash")
    end
  end

  context "when the pause is on a delivery" do
    let(:interrupt) { delivery_interrupt }

    it "exposes the undelivered reply, the error and the attempts" do
      expect(pending_review.kind).to eq(:delivery)
      expect(pending_review.delivery).to have_attributes(
        content: "Great, see you Thursday at 9am!",
        message_id: "ai-1",
        error: "Quiet hours: messages can't be sent before 8am",
        attempts: 3,
        allowed_decisions: %w[approve edit reject],
        interrupt_id: "interrupt-delivery"
      )
      expect(pending_review.reply).to be_nil
      expect(pending_review.tool_calls).to eq([])
    end

    it "edits under the __delivery__ action" do
      expect(pending_review.decisions("action" => "edit", "content" => "See you Thursday!")).to eq(
        [{ "type" => "edit", "edited_action" => { "name" => "__delivery__", "args" => { "content" => "See you Thursday!" } } }]
      )
    end

    it "refuses respond, which a delivery never allows" do
      expect { pending_review.decisions("action" => "respond", "message" => "Hi") }
        .to raise_error(resumption_error, /Invalid review action `respond` for the delivery/)
    end
  end

  context "when the pause is on tool calls" do
    let(:messages) do
      [
        { "type" => "human", "id" => "human-1", "content" => "Confirm it" },
        {
          "type" => "ai",
          "id" => "ai-1",
          "content" => "I've confirmed your appointment.",
          "tool_calls" => [{ "id" => "call-1", "name" => "confirm_appointment", "args" => { "id" => 7 } }],
        },
      ]
    end
    let(:interrupt) do
      {
        "id" => "interrupt-tools",
        "value" => {
          "action_requests" => [{ "name" => "confirm_appointment", "args" => { "id" => 7 } }],
          "review_configs" => [{ "action_name" => "confirm_appointment", "allowed_decisions" => %w[approve reject] }],
        },
      }
    end

    it "lists the held tool calls, and no reply even though the turn has text" do
      expect(pending_review.kind).to eq(:tool_calls)
      expect(pending_review.tool_calls).to eq(
        [
          {
            "previous_message_id" => "human-1",
            "id" => "call-1",
            "name" => "confirm_appointment",
            "args" => { "id" => 7 },
            "allowed_decisions" => %w[approve reject],
          },
        ]
      )
      expect(pending_review.reply).to be_nil
    end

    it "builds the decisions from reviews keyed by tool call id" do
      expect(pending_review.decisions("call-1" => { "action" => "approve" })).to eq([{ "type" => "approve" }])
    end

    it "validates them as a tool call review does" do
      expect { pending_review.decisions("call-1" => { "action" => "edit", "args" => {} }) }
        .to raise_error(resumption_error, "Invalid review action `edit` for tool call call-1")
    end
  end
end
