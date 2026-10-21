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
      review = described_class.from_run("messages" => messages, "__interrupt__" => [reply_interrupt])

      expect(review.interrupt_id).to eq("interrupt-reply")
    end

    it "is nil when the run did not pause" do
      expect(described_class.from_run("messages" => messages)).to be_nil
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

    it "lists the held tool calls" do
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
