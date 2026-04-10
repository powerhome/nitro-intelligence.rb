require "spec_helper"

RSpec.describe NitroIntelligence::ToolCallReviewValidator do
  subject(:validator) { described_class.new }

  let(:pending_tool_calls) do
    [
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
    ]
  end
  let(:thread_state) do
    {
      "interrupts" => [
        {
          "value" => {
            "review_actions" => %w[approve edit],
          },
        },
      ],
    }
  end

  describe "#validate!" do
    it "accepts review hashes with symbol keys" do
      tool_calls = {
        "tool_call_id_1" => { action: "approve" },
        "tool_call_id_2" => {
          action: "edit",
          args: {
            "arg_1" => "new value",
          },
        },
      }

      expect do
        validator.validate!(thread_state:, tool_calls:, pending_tool_calls:)
      end.not_to raise_error
    end

    it "raises when a tool call id is not pending review" do
      tool_calls = {
        "tool_call_id_3" => { "action" => "approve" },
      }

      expect do
        validator.validate!(thread_state:, tool_calls:, pending_tool_calls:)
      end.to raise_error(
        NitroIntelligence::AgentServer::ThreadResumptionError,
        "Unknown tool call ids: tool_call_id_3"
      )
    end

    it "raises when not all pending tool calls are reviewed" do
      tool_calls = {
        "tool_call_id_1" => { "action" => "approve" },
      }

      expect do
        validator.validate!(thread_state:, tool_calls:, pending_tool_calls:)
      end.to raise_error(
        NitroIntelligence::AgentServer::ThreadResumptionError,
        "Missing reviews for tool calls: tool_call_id_2"
      )
    end

    it "raises when edited args are not valid for the tool call" do
      tool_calls = {
        "tool_call_id_2" => {
          "action" => "edit",
          "args" => {
            "arg_3" => "new value",
          },
        },
      }

      expect do
        validator.validate!(thread_state:, tool_calls:, pending_tool_calls:)
      end.to raise_error(
        NitroIntelligence::AgentServer::ThreadResumptionError,
        "Invalid edited args for tool call tool_call_id_2: arg_3"
      )
    end
  end
end
