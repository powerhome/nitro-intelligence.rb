require "spec_helper"
require "nitro_intelligence/server_sent_event_parser"

RSpec.describe NitroIntelligence::ServerSentEventParser do
  it "parses JSON events split across arbitrary response chunks" do
    events = []
    parser = described_class.new { |event| events << event }

    parser << "event: metadata\ndata: {\"run_id\":\"run"
    parser << "-1\"}\n\n"
    parser << "event: messages\ndata: [{\"content\":\"Hel"
    parser << "lo\"}, {\"node\":\"agent\"}]\n\n"

    expect(events).to eq(
      [
        { "event" => "metadata", "data" => { "run_id" => "run-1" } },
        {
          "event" => "messages",
          "data" => [{ "content" => "Hello" }, { "node" => "agent" }],
        },
      ]
    )
  end

  it "joins multiline data and ignores SSE comments" do
    events = []
    parser = described_class.new { |event| events << event }

    parser << ": keep-alive\nevent: custom\ndata: first\ndata: second\n\n"

    expect(events).to eq([{ "event" => "custom", "data" => "first\nsecond" }])
  end

  it "flushes an event without a trailing blank line" do
    events = []
    parser = described_class.new { |event| events << event }

    parser << "event: end\ndata: null"
    parser.finish

    expect(events).to eq([{ "event" => "end", "data" => nil }])
  end
end
