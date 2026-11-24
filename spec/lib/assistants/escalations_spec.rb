require "spec_helper"
require "nitro_intelligence/assistants"
require "webmock/rspec"

RSpec.describe NitroIntelligence::Assistants, "escalations" do
  include_context "with an Assistants thread"

  let(:base_url) { "https://assistants.example.com" }
  let(:assistants) { described_class.new(base_url:, api_key: "test-api-key", user_id: "user-123") }
  let(:assistant_id) { "sunbeam-booking" }
  let(:escalation_url) { "#{base_url}/threads/#{thread_id}/escalation" }
  let(:summary) do
    {
      "id" => "esc-7f3a91c2d4e5", "status" => "open", "source" => "judge", "reason" => "asked_for_person",
      "at" => "2026-11-12T14:03:00Z", "delivery" => { "status" => "delivered" }
    }
  end

  def conflict(code, details)
    { "error" => "conflict", "message" => "refused", "details" => { "code" => code, **details } }
  end

  describe "#run" do
    let(:messages) { [{ "type" => "human", "content" => "Hello?" }] }

    before do
      stub_json(:get, "#{base_url}/assistants/#{assistant_id}", { "graph_id" => "react-agent" })
      stub_json(:post, "#{base_url}/threads", {}, status: 409)
    end

    context "when the thread is escalated" do
      before { stub_json(:post, run_url, conflict("thread_escalated", "escalation" => summary), status: 409) }

      it "raises ThreadEscalatedError carrying the stamp's summary" do
        expect { assistants.run(thread_id:, assistant_id:, messages:) }
          .to raise_error(described_class::ThreadEscalatedError) { |error|
            expect(error.escalation).to have_attributes(id: "esc-7f3a91c2d4e5", status: "open", reason: "asked_for_person")
            expect(error.escalation.delivery).to be_delivered
            expect(error.message).to include("thread_escalated")
          }
      end

      it "is a RunError" do
        expect { assistants.run(thread_id:, assistant_id:, messages:) }.to raise_error(described_class::RunError)
      end
    end

    context "when a run admitted before the stamp fails instead" do
      before do
        failure = { "error" => "ThreadEscalated",
                    "message" => "thread_escalated: escalation esc-1 is open; resolve it before starting a run" }
        stub_json(:post, run_url, { "__error__" => failure })
      end

      it "raises ThreadEscalatedError with the escalation's id and status" do
        expect { assistants.run(thread_id:, assistant_id:, messages:) }
          .to raise_error(described_class::ThreadEscalatedError, /thread_escalated: escalation esc-1/) { |error|
            expect(error.escalation).to have_attributes(id: "esc-1", status: "open")
          }
      end
    end

    context "when the run is refused with another conflict" do
      before { stub_json(:post, run_url, conflict("thread_busy", {}), status: 409) }

      it "raises a plain RunError" do
        expect { assistants.run(thread_id:, assistant_id:, messages:) }
          .to raise_error(described_class::RunError) { |error|
            expect(error).not_to be_a(described_class::ThreadEscalatedError)
          }
      end
    end

    context "when the run escalates" do
      before do
        stub_json(:post, run_url, { "messages" => messages, "escalation" => summary.merge("outcome" => "escalated") })
      end

      it "returns the escalation on the result" do
        result = assistants.run(thread_id:, assistant_id:, messages:)

        expect(result).to be_escalated
        expect(result.escalation.id).to eq("esc-7f3a91c2d4e5")
      end
    end
  end

  describe "#hand_back_escalation" do
    let(:reply_run) do
      { "messages" => [{ "type" => "ai", "content" => "Yes, we'll text you the day before." }], "escalation" => nil }
    end
    let(:person_messages) do
      [{ "type" => "human", "content" => "Fine, Friday morning then." },
       { "type" => "ai", "name" => "agent:jane", "content" => "Booked you for Friday at 9." }]
    end

    it "hands back, and returns the reply run" do
      stub_json(:post, escalation_url, reply_run)

      result = assistants.hand_back_escalation(
        thread_id:, assistant_id:, escalation_id: "esc-1", reviewer_id: "jane@sunbeam.example",
        note: "Moved the visit to Friday at 9 by phone.", messages: person_messages,
        context: { "prompt_variables" => { "customer_name" => "Ana" } }, reviewed_at: "2026-11-12T15:10:00Z"
      )

      expect(result).to be_a(NitroIntelligence::RunResult)
      expect(result.reply).to eq("Yes, we'll text you the day before.")
      expect(WebMock).to have_requested(:post, escalation_url).with(body: {
                                                                      "assistant_id" => assistant_id,
                                                                      "escalation_id" => "esc-1",
                                                                      "decision" => {
                                                                        "type" => "hand_back", "note" => "Moved the visit to Friday at 9 by phone.",
                                                                        "messages" => person_messages, "reply" => true,
                                                                        "context" => { "prompt_variables" => { "customer_name" => "Ana" } }
                                                                      },
                                                                      "reviewer_id" => "jane@sunbeam.example",
                                                                      "reviewed_at" => "2026-11-12T15:10:00Z",
                                                                    })
    end

    it "sends only what is given, and stamps now" do
      stub_json(:post, escalation_url, reply_run)

      assistants.hand_back_escalation(thread_id:, assistant_id:, escalation_id: "esc-1", reviewer_id: "jane")

      expect(WebMock).to(have_requested(:post, escalation_url).with do |request|
        body = JSON.parse(request.body)
        body["decision"] == { "type" => "hand_back", "messages" => [], "reply" => true, "context" => {} } &&
          Time.iso8601(body["reviewed_at"]).between?(Time.now - 60, Time.now + 1)
      end)
    end

    it "returns the escalation when the assistant does not reply" do
      stub_json(:post, escalation_url,
                { "escalation" => summary.merge("status" => "handed_back", "resolved_by" => "jane") })

      result = assistants.hand_back_escalation(thread_id:, assistant_id:, escalation_id: "esc-1",
                                               reviewer_id: "jane", reply: false)

      expect(result).to be_a(NitroIntelligence::Escalation)
      expect(result).to be_handed_back
      expect(result.resolved_by).to eq("jane")
      expect(WebMock).to have_requested(:post, escalation_url)
        .with(body: hash_including("decision" => hash_including("reply" => false)))
    end

    it "raises EscalationNotOpenError when another person resolved it first" do
      stub_json(:post, escalation_url,
                conflict("escalation_not_open", "escalation" => { "id" => "esc-1", "status" => "closed" }),
                status: 409)

      expect do
        assistants.hand_back_escalation(thread_id:, assistant_id:, escalation_id: "esc-1", reviewer_id: "jane")
      end.to raise_error(described_class::EscalationNotOpenError) { |error|
        expect(error.escalation).to be_closed
        expect(error).to be_a(described_class::EscalationResolutionError)
      }
    end

    it "raises EscalationNotOpenError without an escalation when the thread has none" do
      stub_json(:post, escalation_url, conflict("escalation_not_open", "escalation" => nil), status: 409)

      expect do
        assistants.hand_back_escalation(thread_id:, assistant_id:, escalation_id: "esc-1", reviewer_id: "jane")
      end.to raise_error(described_class::EscalationNotOpenError) { |error| expect(error.escalation).to be_nil }
    end

    it "raises EscalationResolutionError with the body when Assistants refuses it" do
      stub_request(:post, escalation_url).to_return(status: 422, body: '{"error":"validation"}')

      expect do
        assistants.hand_back_escalation(thread_id:, assistant_id:, escalation_id: "esc-1", reviewer_id: "jane",
                                        note: "x" * 2001)
      end.to raise_error(described_class::EscalationResolutionError, '{"error":"validation"}')
    end

    it "raises RunError when the reply run fails" do
      stub_json(:post, escalation_url, { "__error__" => { "error" => "KeyError", "message" => "missing variables" } })

      expect do
        assistants.hand_back_escalation(thread_id:, assistant_id:, escalation_id: "esc-1", reviewer_id: "jane")
      end.to raise_error(described_class::RunError, "KeyError: missing variables")
    end

    it "requires an escalation and a reviewer" do
      expect do
        assistants.hand_back_escalation(thread_id:, assistant_id:, escalation_id: "", reviewer_id: "jane")
      end.to raise_error(ArgumentError, "escalation_id is required")
      expect do
        assistants.hand_back_escalation(thread_id:, assistant_id:, escalation_id: "esc-1", reviewer_id: nil)
      end.to raise_error(ArgumentError, "reviewer_id is required")
      expect(WebMock).not_to have_requested(:post, escalation_url)
    end
  end

  describe "#close_escalation" do
    it "closes it, and returns the escalation" do
      stub_json(:post, escalation_url, { "escalation" => summary.merge("status" => "closed") })

      result = assistants.close_escalation(thread_id:, assistant_id:, escalation_id: "esc-1", reviewer_id: "jane",
                                           reviewed_at: Time.utc(2026, 11, 12, 15, 10))

      expect(result).to be_closed
      expect(WebMock).to have_requested(:post, escalation_url).with(body: {
                                                                      "assistant_id" => assistant_id, "escalation_id" => "esc-1", "decision" => { "type" => "close" },
                                                                      "reviewer_id" => "jane", "reviewed_at" => "2026-11-12T15:10:00Z"
                                                                    })
    end
  end
end
