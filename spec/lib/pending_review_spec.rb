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
          { "action_name" => "__delivery__", "allowed_decisions" => %w[retry reject] },
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

    context "when the reply's config lists retry" do
      let(:reply_allowed_decisions) { %w[approve retry] }

      it "refuses it, as a delivery's decision only" do
        expect { pending_review.decisions("action" => "retry") }
          .to raise_error(resumption_error, "Unsupported review action `retry` for the reply")
      end
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
        allowed_decisions: %w[retry reject],
        interrupt_id: "interrupt-delivery"
      )
      expect(pending_review.reply).to be_nil
      expect(pending_review.tool_calls).to eq([])
    end

    it "retries" do
      expect(pending_review.decisions("action" => "retry")).to eq([{ "type" => "retry" }])
    end

    it "gives up, with or without a reason" do
      expect(pending_review.decisions("action" => "reject", "message" => "Customer opted out")).to eq(
        [{ "type" => "reject", "message" => "Customer opted out" }]
      )
      expect(pending_review.decisions("action" => "reject")).to eq([{ "type" => "reject" }])
    end

    it "refuses approve, edit and respond, which a delivery never allows" do
      [
        { "action" => "approve" },
        { "action" => "edit", "content" => "See you Thursday!" },
        { "action" => "respond", "message" => "Hi" },
      ].each do |review|
        expect { pending_review.decisions(review) }
          .to raise_error(resumption_error,
                          "Invalid review action `#{review['action']}` for the delivery; allowed: retry, reject")
      end
    end

    context "when the interrupt lists other decisions than the fixed ones" do
      let(:interrupt) do
        delivery_interrupt.deep_merge(
          "value" => {
            "review_configs" => [{ "action_name" => "__delivery__", "allowed_decisions" => %w[approve edit] }],
          }
        )
      end

      it "still allows retry and reject, and only those" do
        expect(pending_review.delivery.allowed_decisions).to eq(%w[retry reject])
        expect(pending_review.decisions("action" => "reject")).to eq([{ "type" => "reject" }])
        expect { pending_review.decisions("action" => "edit", "content" => "Hi") }
          .to raise_error(resumption_error, /Invalid review action `edit` for the delivery/)
      end
    end

    context "when the interrupt carries no review config" do
      let(:interrupt) { delivery_interrupt.deep_merge("value" => { "review_configs" => [] }) }

      it "allows the fixed decisions" do
        expect(pending_review.decisions("action" => "retry")).to eq([{ "type" => "retry" }])
      end
    end

    it "has no failure time and no retries when the held reply carries no delivery stamp" do
      expect(pending_review.delivery).to have_attributes(failed_at: nil, retries: [])
    end

    context "when the held reply's delivery stamp records the failure and earlier retries" do
      let(:retry_entry) do
        {
          "reviewer_id" => "ops@example.com",
          "reviewed_at" => "2026-10-22T07:00:00Z",
          "error" => "Gateway timeout",
          "attempts" => 3,
        }
      end
      let(:stamp) do
        {
          "status" => "failed",
          "tool" => "send_sms",
          "attempts" => 3,
          "error" => "Quiet hours: messages can't be sent before 8am",
          "failed_at" => "2026-10-22T07:58:02Z",
          "retries" => [retry_entry],
        }
      end
      let(:messages) do
        [
          { "type" => "human", "id" => "human-1", "content" => "Thursday works." },
          { "type" => "ai", "id" => "ai-0", "content" => "Earlier reply",
            "response_metadata" => { "delivery" => { "failed_at" => "2026-10-01T00:00:00Z" } } },
          { "type" => "ai", "id" => "ai-1", "content" => "Great, see you Thursday at 9am!",
            "response_metadata" => { "delivery" => stamp } },
        ]
      end

      it "reads them from the message the pause names" do
        expect(pending_review.delivery.failed_at).to eq("2026-10-22T07:58:02Z")
        expect(pending_review.delivery.retries).to eq(
          [
            described_class::DeliveryRetry.new(
              reviewer_id: "ops@example.com", reviewed_at: "2026-10-22T07:00:00Z",
              error: "Gateway timeout", attempts: 3
            ),
          ]
        )
      end

      context "with malformed entries in the history" do
        let(:stamp) do
          {
            "failed_at" => 1_729_583_882,
            "retries" => ["retried", nil, retry_entry.merge("attempts" => "3", "error" => nil), retry_entry],
          }
        end

        it "skips what is not an entry, and leaves out fields of the wrong type" do
          expect(pending_review.delivery.failed_at).to be_nil
          expect(pending_review.delivery.retries.map(&:to_h)).to eq(
            [
              retry_entry.symbolize_keys.merge(attempts: nil, error: nil),
              retry_entry.symbolize_keys,
            ]
          )
        end
      end

      context "when the history is not a list" do
        let(:stamp) { { "retries" => { "reviewer_id" => "ops@example.com" } } }

        it "reports no retries" do
          expect(pending_review.delivery.retries).to eq([])
        end
      end
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
    let(:newer) { delivery_interrupt }
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

    it "reads no state when the run did not pause, or paused on the interrupt it was sent to" do
      [{ "messages" => messages }, { "messages" => messages, "__interrupt__" => [reply_interrupt] }].each do |ended|
        expect(pending_review.unapplied_resume?(run: ended, run_id: "run-mine") { raise "read" }).to be(false)
      end
    end

    it "is false without the run's id, or when the state cannot be read" do
      expect(pending_review.unapplied_resume?(run:, run_id: nil) { state(written_by: "run-theirs") }).to be(false)
      expect(pending_review.unapplied_resume?(run:, run_id: "run-mine") { raise resumption_error, "boom" }).to be(false)
    end
  end
end
