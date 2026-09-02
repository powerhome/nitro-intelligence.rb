require "spec_helper"

RSpec.describe NitroIntelligence::ToolCallReviewInterrupt do
  subject(:interrupt) { described_class.new(thread_state) }

  let(:messages) do
    [
      {
        "type" => "human",
        "id" => "communication-1",
        "content" => "Please look up my account",
      },
      {
        "type" => "ai",
        "id" => "ai-message-1",
        "content" => "",
        "tool_calls" => [
          {
            "id" => "tool_call_id_1",
            "name" => "lookup_account",
            "args" => {},
          },
          {
            "id" => "tool_call_id_2",
            "name" => "lookup_orders",
            "args" => {
              "arg_1" => "original value",
              "arg_2" => "original value",
            },
          },
        ],
      },
    ]
  end
  let(:action_requests) do
    [
      {
        "name" => "lookup_account",
        "args" => {},
        "description" => "Tool execution requires approval",
      },
      {
        "name" => "lookup_orders",
        "args" => {
          "arg_1" => "original value",
          "arg_2" => "original value",
        },
        "description" => "Tool execution requires approval",
      },
    ]
  end
  let(:review_configs) do
    [
      { "action_name" => "lookup_account", "allowed_decisions" => %w[approve reject] },
      { "action_name" => "lookup_orders", "allowed_decisions" => %w[approve edit reject respond] },
    ]
  end
  let(:thread_state) do
    {
      "values" => { "messages" => messages },
      "interrupts" => [
        {
          "value" => {
            "action_requests" => action_requests,
            "review_configs" => review_configs,
          },
        },
      ],
    }
  end

  describe "#tool_calls" do
    it "recovers each action request's tool call id, arguments and allowed decisions" do
      expect(interrupt.tool_calls).to eq(
        [
          {
            "previous_message_id" => "communication-1",
            "id" => "tool_call_id_1",
            "name" => "lookup_account",
            "args" => {},
            "allowed_decisions" => %w[approve reject],
          },
          {
            "previous_message_id" => "communication-1",
            "id" => "tool_call_id_2",
            "name" => "lookup_orders",
            "args" => {
              "arg_1" => "original value",
              "arg_2" => "original value",
            },
            "allowed_decisions" => %w[approve edit reject respond],
          },
        ]
      )
    end

    context "when only some of the AI message's tool calls are under review" do
      let(:action_requests) { [super().last] }
      let(:review_configs) { [super().last] }

      it "leaves the auto-approved tool calls out" do
        expect(interrupt.tool_calls.map { |tool_call| tool_call["id"] }).to eq(%w[tool_call_id_2])
      end
    end

    context "when the same tool is called twice" do
      let(:messages) do
        [
          {
            "type" => "ai",
            "id" => "ai-message-1",
            "tool_calls" => [
              { "id" => "tool_call_id_1", "name" => "lookup_orders", "args" => { "arg_1" => "first" } },
              { "id" => "tool_call_id_2", "name" => "lookup_orders", "args" => { "arg_1" => "second" } },
            ],
          },
        ]
      end
      let(:action_requests) do
        [
          { "name" => "lookup_orders", "args" => { "arg_1" => "second" } },
          { "name" => "lookup_orders", "args" => { "arg_1" => "first" } },
        ]
      end
      let(:review_configs) do
        [{ "action_name" => "lookup_orders", "allowed_decisions" => %w[approve] }]
      end

      it "matches each action request to the tool call carrying its arguments" do
        expect(interrupt.tool_calls.map { |tool_call| tool_call["id"] }).to eq(%w[tool_call_id_2 tool_call_id_1])
      end
    end

    context "when the AI message is the first message in the thread" do
      let(:messages) { [super().last] }

      it "reports no previous message id" do
        expect(interrupt.tool_calls.map { |tool_call| tool_call["previous_message_id"] }).to eq([nil, nil])
      end
    end

    context "when the interrupt is not a tool call review" do
      let(:thread_state) { { "values" => { "messages" => messages }, "interrupts" => [] } }

      it "is empty" do
        expect(interrupt.tool_calls).to be_empty
      end
    end

    context "when no tool call matches an action request" do
      let(:action_requests) { [{ "name" => "send_invoice", "args" => {} }] }

      it "raises ThreadResumptionError" do
        expect { interrupt.tool_calls }.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "No tool call on the thread matches the interrupt's action request for `send_invoice`"
        )
      end
    end
  end

  describe "#decisions" do
    it "orders the decisions to match the action requests" do
      decisions = interrupt.decisions(
        "tool_call_id_2" => { "action" => "reject" },
        "tool_call_id_1" => { "action" => "approve" }
      )

      expect(decisions).to eq(
        [
          { "type" => "approve" },
          { "type" => "reject" },
        ]
      )
    end

    it "sends a rejection's message when there is one" do
      decisions = interrupt.decisions(
        "tool_call_id_1" => { "action" => "reject", "message" => "Wrong account" },
        "tool_call_id_2" => { "action" => "approve" }
      )

      expect(decisions.first).to eq("type" => "reject", "message" => "Wrong account")
    end

    it "sends a response's message as the tool result" do
      decisions = interrupt.decisions(
        "tool_call_id_1" => { "action" => "approve" },
        "tool_call_id_2" => { action: "respond", message: "There are no open orders" }
      )

      expect(decisions.last).to eq("type" => "respond", "message" => "There are no open orders")
    end

    it "merges edited args over the arguments the model asked for" do
      decisions = interrupt.decisions(
        "tool_call_id_1" => { "action" => "approve" },
        "tool_call_id_2" => { "action" => "edit", "args" => { "arg_1" => "new value" } }
      )

      expect(decisions.last).to eq(
        "type" => "edit",
        "edited_action" => {
          "name" => "lookup_orders",
          "args" => {
            "arg_1" => "new value",
            "arg_2" => "original value",
          },
        }
      )
    end
  end
end
