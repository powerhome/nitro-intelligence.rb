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
    reply_interrupt_for(
      "Sure! You're booked for Tuesday at 10am.", allowed: reply_allowed_decisions, description: "Review this SMS"
    )
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
      expect(described_class.from_run("messages" => messages, "__interrupt__" => [reply_interrupt])).to be_reply
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

    it "holds no tool calls" do
      expect(pending_review).not_to be_tool_calls
      expect(pending_review.tool_calls).to eq([])
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

    it "refuses respond, which a reply never allows" do
      expect { pending_review.decisions("action" => "respond", "message" => "Hi") }
        .to raise_error(resumption_error, "Invalid review action `respond` for the reply; allowed: approve, edit, reject")
    end

    context "when the interrupt lists respond for the reply" do
      let(:reply_allowed_decisions) { %w[approve respond] }

      it "leaves it out of the allowed decisions and refuses it" do
        expect(pending_review.reply.allowed_decisions).to eq(%w[approve])
        expect { pending_review.decisions("action" => "respond", "message" => "Hi") }
          .to raise_error(resumption_error, "Invalid review action `respond` for the reply; allowed: approve")
      end
    end

    context "when the interrupt allows approve and reject only" do
      let(:reply_allowed_decisions) { %w[approve reject] }

      it "refuses an edit" do
        expect { pending_review.decisions("action" => "edit", "content" => "Hi") }
          .to raise_error(resumption_error, /Invalid review action `edit` for the reply/)
      end
    end

    it "refuses an edit without content" do
      expect { pending_review.decisions("action" => "edit", "content" => " ") }
        .to raise_error(resumption_error, /`edit` review of the reply must include a non-empty `content`/)
    end

    it "refuses content that is not a string as mistyped, not missing" do
      expect { pending_review.decisions("action" => "edit", "content" => 5) }
        .to raise_error(resumption_error, /`content` for the reply review must be a string/)
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

  context "when the pause is on tool calls" do
    let(:messages) do
      [
        { "type" => "human", "id" => "human-1", "content" => "Cancel it" },
        {
          "type" => "ai",
          "id" => "ai-1",
          "content" => "Let me cancel that.",
          "tool_calls" => [
            { "id" => "call-1", "name" => "cancel_appointment", "args" => { "id" => 7 } },
            { "id" => "call-2", "name" => "notify_office", "args" => {} },
          ],
        },
      ]
    end
    let(:interrupt) do
      interrupt_for(
        [{ "name" => "cancel_appointment", "args" => { "id" => 7 } }, { "name" => "notify_office", "args" => {} }],
        allowed: { "cancel_appointment" => %w[approve reject], "notify_office" => %w[approve edit reject respond] },
        id: "interrupt-tools"
      )
    end

    it "lists the held tool calls, and no reply though the turn has text" do
      expect(pending_review.kind).to eq(:tool_calls)
      expect(pending_review.tool_calls.first).to eq(
        "previous_message_id" => "human-1",
        "id" => "call-1",
        "name" => "cancel_appointment",
        "args" => { "id" => 7 },
        "allowed_decisions" => %w[approve reject]
      )
      expect(pending_review.reply).to be_nil
    end

    it "builds the decisions from reviews keyed by tool call id, in the interrupt's order" do
      reviews = { "call-2" => { "action" => "respond", "message" => "Done" }, "call-1" => { "action" => "approve" } }

      expect(pending_review.decisions(reviews)).to eq(
        [{ "type" => "approve" }, { "type" => "respond", "message" => "Done" }]
      )
    end

    it "builds the same from a list of reviews that each carry their tool call's id" do
      reviews = [
        { "id" => "call-2", "action" => "respond", "message" => "Done" },
        { "id" => "call-1", "action" => "reject", "message" => "Customer called in" },
      ]

      expect(pending_review.decisions(reviews)).to eq(
        [{ "type" => "reject", "message" => "Customer called in" }, { "type" => "respond", "message" => "Done" }]
      )
    end

    it "refuses two reviews of the same tool call" do
      reviews = [{ "id" => "call-1", "action" => "approve" }, { id: "call-1", "action" => "reject" }]

      expect { pending_review.decisions(reviews) }
        .to raise_error(resumption_error, "Tool call `call-1` is reviewed more than once")
    end

    it "refuses a list entry without an id" do
      expect { pending_review.decisions([{ "action" => "approve" }]) }
        .to raise_error(resumption_error, "Each tool call review in a list must be a hash with the tool call's `id`")
    end

    it "validates them as a tool call review does" do
      expect { pending_review.decisions("call-1" => { "action" => "edit", "args" => {} }, "call-2" => { "action" => "approve" }) }
        .to raise_error(resumption_error, "Invalid review action `edit` for tool call call-1")
    end
  end

  describe "#resume" do
    it "keys the decisions by the pause's interrupt" do
      expect(pending_review.resume([{ "type" => "approve" }]))
        .to eq("interrupt-reply" => { decisions: [{ "type" => "approve" }] })
    end

    context "when the interrupt reports no id" do
      let(:interrupt) { reply_interrupt.except("id") }

      it "sends them unkeyed" do
        expect(pending_review.resume([{ "type" => "approve" }])).to eq(decisions: [{ "type" => "approve" }])
      end
    end
  end

  describe "#unapplied_resume?" do
    let(:newer) { reply_interrupt_for("Another draft", id: "interrupt-newer") }
    let(:run) { { "messages" => messages, "__interrupt__" => [newer] } }

    def state(written_by:, interrupt: newer)
      { "values" => { "messages" => messages }, "interrupts" => [interrupt], "metadata" => { "run_id" => written_by } }
    end

    it "is true when the reported pause sits on a checkpoint another run wrote" do
      expect(pending_review.unapplied_resume?(run:, run_id: "run-mine") { state(written_by: "run-theirs") }).to be(true)
    end

    it "is false when this run wrote it, having applied the decision and paused again" do
      expect(pending_review.unapplied_resume?(run:, run_id: "run-mine") { state(written_by: "run-mine") }).to be(false)
    end

    it "reads no state when the run did not pause" do
      expect(pending_review.unapplied_resume?(run: { "messages" => messages }, run_id: "run-mine") { raise "read" })
        .to be(false)
    end

    it "reads no state when the run paused on the interrupt it was sent to" do
      paused = { "messages" => messages, "__interrupt__" => [reply_interrupt] }

      expect(pending_review.unapplied_resume?(run: paused, run_id: "run-mine") { raise "read" }).to be(false)
    end

    it "is false without the run's id" do
      expect(pending_review.unapplied_resume?(run:, run_id: nil) { state(written_by: "run-theirs") }).to be(false)
    end

    it "is false when the state cannot be read" do
      expect(pending_review.unapplied_resume?(run:, run_id: "run-mine") { raise resumption_error, "boom" }).to be(false)
    end

    it "is false when the thread has moved past the reported pause" do
      expect(pending_review.unapplied_resume?(run:, run_id: "run-mine") { state(written_by: "run-x", interrupt: nil) })
        .to be(false)
    end
  end
end
