require "spec_helper"

RSpec.describe NitroIntelligence::ToolCallReviewValidator do
  subject(:validator) { described_class.new }

  let(:allowed_decisions) { %w[approve edit reject respond] }
  let(:tool_calls_under_review) do
    [
      {
        "id" => "tool_call_id_1",
        "name" => "lookup_account",
        "args" => {},
        "allowed_decisions" => allowed_decisions,
      },
      {
        "id" => "tool_call_id_2",
        "name" => "lookup_orders",
        "args" => {
          "arg_1" => "original value",
          "arg_2" => "original value",
        },
        "allowed_decisions" => allowed_decisions,
      },
    ]
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
        validator.validate!(tool_calls:, tool_calls_under_review:)
      end.not_to raise_error
    end

    it "accepts rejections with and without a message" do
      tool_calls = {
        "tool_call_id_1" => { "action" => "reject" },
        "tool_call_id_2" => { "action" => "reject", "message" => "Not this account" },
      }

      expect do
        validator.validate!(tool_calls:, tool_calls_under_review:)
      end.not_to raise_error
    end

    it "raises when a tool call id is not under review" do
      tool_calls = {
        "tool_call_id_3" => { "action" => "approve" },
      }

      expect do
        validator.validate!(tool_calls:, tool_calls_under_review:)
      end.to raise_error(
        NitroIntelligence::Assistants::ThreadResumptionError,
        "Unknown tool call ids: tool_call_id_3"
      )
    end

    it "raises when not all tool calls under review are reviewed" do
      tool_calls = {
        "tool_call_id_1" => { "action" => "approve" },
      }

      expect do
        validator.validate!(tool_calls:, tool_calls_under_review:)
      end.to raise_error(
        NitroIntelligence::Assistants::ThreadResumptionError,
        "Missing reviews for tool calls: tool_call_id_2"
      )
    end

    context "when the interrupt allows only some of the decisions" do
      let(:allowed_decisions) { %w[approve] }

      it "raises for a review action the interrupt does not allow" do
        tool_calls = {
          "tool_call_id_1" => { "action" => "approve" },
          "tool_call_id_2" => { "action" => "reject" },
        }

        expect do
          validator.validate!(tool_calls:, tool_calls_under_review:)
        end.to raise_error(
          NitroIntelligence::Assistants::ThreadResumptionError,
          "Invalid review action `reject` for tool call tool_call_id_2"
        )
      end
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
        validator.validate!(tool_calls:, tool_calls_under_review:)
      end.to raise_error(
        NitroIntelligence::Assistants::ThreadResumptionError,
        "Invalid edited args for tool call tool_call_id_2: arg_3"
      )
    end

    it "raises when a response carries no message" do
      tool_calls = {
        "tool_call_id_1" => { "action" => "respond" },
        "tool_call_id_2" => { "action" => "approve" },
      }

      expect do
        validator.validate!(tool_calls:, tool_calls_under_review:)
      end.to raise_error(
        NitroIntelligence::Assistants::ThreadResumptionError,
        "Review for tool call tool_call_id_1 must include a message"
      )
    end

    it "raises when a response message is blank" do
      tool_calls = {
        "tool_call_id_1" => { "action" => "respond", "message" => "  " },
        "tool_call_id_2" => { "action" => "approve" },
      }

      expect do
        validator.validate!(tool_calls:, tool_calls_under_review:)
      end.to raise_error(
        NitroIntelligence::Assistants::ThreadResumptionError,
        "Review for tool call tool_call_id_1 must include a message"
      )
    end

    it "raises when a message is not a string" do
      tool_calls = {
        "tool_call_id_1" => { "action" => "reject", "message" => { "reason" => "no" } },
        "tool_call_id_2" => { "action" => "approve" },
      }

      expect do
        validator.validate!(tool_calls:, tool_calls_under_review:)
      end.to raise_error(
        NitroIntelligence::Assistants::ThreadResumptionError,
        "Message for tool call tool_call_id_1 must be a string"
      )
    end
  end
end
