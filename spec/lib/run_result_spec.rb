require "spec_helper"
require "nitro_intelligence/assistants"

RSpec.describe NitroIntelligence::RunResult do
  subject(:result) { described_class.new(run) }

  let(:human) { { "type" => "human", "id" => "human-1", "content" => "Can I move my appointment?" } }
  let(:draft) { { "type" => "ai", "id" => "ai-1", "content" => "Sure! You're booked for Tuesday at 10am." } }

  context "when the run ended with a reply" do
    let(:run) { { "messages" => [human, draft] } }

    it "returns the reply" do
      expect(result).not_to be_interrupted
      expect(result.reply).to eq("Sure! You're booked for Tuesday at 10am.")
      expect(result.review).to be_nil
    end
  end

  context "when the run paused on the reply" do
    let(:run) do
      {
        "messages" => [human, draft],
        "__interrupt__" => [
          {
            "id" => "interrupt-1",
            "value" => {
              "action_requests" => [{ "name" => "__reply__", "args" => { "content" => draft["content"] } }],
              "review_configs" => [{ "action_name" => "__reply__", "allowed_decisions" => %w[approve edit reject] }],
            },
          },
        ],
      }
    end

    it "holds the draft back from the reply" do
      expect(result).to be_interrupted
      expect(result.reply).to be_nil
      expect(result.review.reply.content).to eq("Sure! You're booked for Tuesday at 10am.")
    end
  end

  context "when a rejected draft left the human's message last" do
    let(:run) { { "messages" => [human] } }

    it "has no reply" do
      expect(result.reply).to be_nil
    end
  end

  context "when the last message only calls tools" do
    let(:run) { { "messages" => [human, draft.merge("content" => "", "tool_calls" => [{ "id" => "c" }])] } }

    it "has no reply" do
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

  it "keeps the raw response" do
    expect(described_class.new("messages" => []).raw).to eq("messages" => [])
  end
end
