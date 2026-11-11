require "spec_helper"
require "nitro_intelligence/client/handlers/base_handler"

RSpec.describe NitroIntelligence::Client::Handlers::BaseHandler do
  subject(:handler) { described_class.new(client: double("client")) }

  describe "#add_request_headers" do
    it "creates request_options.extra_headers when none exist" do
      parameters = {}

      handler.send(:add_request_headers, parameters, "nip-modality" => "image")

      expect(parameters).to eq(request_options: { extra_headers: { "nip-modality" => "image" } })
    end

    it "merges headers without clobbering existing request_options (e.g. extra_body)" do
      parameters = {
        request_options: {
          extra_body: { image_config: { image_size: "4K" } },
          extra_headers: { "existing" => "1" },
        },
      }

      handler.send(:add_request_headers, parameters, "nip-modality" => "image")

      expect(parameters[:request_options][:extra_body]).to eq(image_config: { image_size: "4K" })
      expect(parameters[:request_options][:extra_headers]).to eq("existing" => "1", "nip-modality" => "image")
    end

    it "drops headers with nil values (HTTP clients reject a nil header value)" do
      parameters = {}

      handler.send(:add_request_headers, parameters, "nip-modality" => "image", "nip-requested-model" => nil)

      expect(parameters[:request_options][:extra_headers]).to eq("nip-modality" => "image")
    end

    it "returns the parameters hash" do
      parameters = {}

      expect(handler.send(:add_request_headers, parameters, "a" => "b")).to be(parameters)
    end
  end

  describe "#add_correlation_headers" do
    let(:trace_id) { "abcdef0123456789abcdef0123456789" }

    it "sends the supplied trace ID to the inference gateway" do
      parameters = {}

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters.dig(:request_options, :extra_headers, "x-litellm-trace-id")).to eq(trace_id)
    end

    it "sends metadata to the gateway spend logs" do
      parameters = { metadata: { source: "MyJob", rails_request_id: "req-1" } }

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters.dig(:request_options, :extra_headers, "x-litellm-spend-logs-metadata"))
        .to eq('{"source":"MyJob","rails_request_id":"req-1"}')
    end

    it "omits the metadata header when there is no metadata" do
      parameters = { metadata: {} }

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters[:request_options][:extra_headers]).not_to have_key("x-litellm-spend-logs-metadata")
    end

    it "omits metadata that would exceed the header size limit" do
      allow(NitroIntelligence).to receive(:logger).and_return(double("Logger", warn: nil))
      parameters = { metadata: { blob: "x" * 5000 } }

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters[:request_options][:extra_headers]).not_to have_key("x-litellm-spend-logs-metadata")
      expect(parameters.dig(:request_options, :extra_headers, "x-litellm-trace-id")).to eq(trace_id)
    end

    it "preserves headers added by the caller" do
      parameters = {}
      handler.send(:add_request_headers, parameters, "nip-modality" => "image")

      handler.send(:add_correlation_headers, parameters, trace_id:)

      expect(parameters.dig(:request_options, :extra_headers, "nip-modality")).to eq("image")
    end

    context "when no trace ID is supplied (the unobserved client)" do
      it "sends no trace ID" do
        parameters = { metadata: { source: "MyJob" } }

        handler.send(:add_correlation_headers, parameters, trace_id: nil)

        expect(parameters[:request_options][:extra_headers]).not_to have_key("x-litellm-trace-id")
      end

      it "still attributes gateway spend, which does not depend on anything observing" do
        parameters = { metadata: { source: "MyJob" } }

        handler.send(:add_correlation_headers, parameters, trace_id: nil)

        expect(parameters.dig(:request_options, :extra_headers, "x-litellm-spend-logs-metadata"))
          .to eq('{"source":"MyJob"}')
      end

      it "adds nothing at all when there is no metadata either" do
        parameters = {}

        expect(handler.send(:add_correlation_headers, parameters, trace_id: nil)).to be(parameters)
        expect(parameters[:request_options][:extra_headers]).to eq({})
      end
    end
  end

  describe "#add_gateway_headers" do
    it "sends every gateway header together, keeping the caller's own" do
      parameters = {
        model: "gpt-image-1",
        metadata: { ticket: "1" },
        request_options: { extra_headers: { "x-caller" => "kept" } },
      }

      handler.send(:add_gateway_headers, parameters, correlation_trace_id: "abc123", mask_content: true,
                                                     modality: "image")

      expect(parameters.dig(:request_options, :extra_headers)).to eq(
        "x-caller" => "kept",
        "nip-modality" => "image",
        "nip-requested-model" => "gpt-image-1",
        "x-litellm-trace-id" => "abc123",
        "x-litellm-spend-logs-metadata" => '{"ticket":"1"}',
        "x-litellm-enable-message-redaction" => "true"
      )
    end

    it "sends only the requested model when there is nothing else to say" do
      parameters = { model: "gpt-4o" }

      handler.send(:add_gateway_headers, parameters, correlation_trace_id: nil, mask_content: false)

      expect(parameters.dig(:request_options, :extra_headers)).to eq("nip-requested-model" => "gpt-4o")
    end
  end

  describe "#add_message_redaction_header" do
    it "asks the gateway to redact the request's messages and response from its logs" do
      parameters = {}

      handler.send(:add_message_redaction_header, parameters, mask_content: true)

      expect(parameters.dig(:request_options, :extra_headers, "x-litellm-enable-message-redaction")).to eq("true")
    end

    it "sends no header for a project that does not mask content" do
      parameters = {}

      handler.send(:add_message_redaction_header, parameters, mask_content: false)

      expect(parameters[:request_options][:extra_headers]).to eq({})
    end
  end

  describe "#cost_details" do
    def response_with(headers)
      double("Response", last_response: double("LastResponse", headers: headers))
    end

    it "reads the total and the component breakdown the gateway calculated" do
      response = response_with(
        "x-litellm-response-cost" => "5.85e-06",
        "x-litellm-response-cost-input" => "1.1e-06",
        "x-litellm-response-cost-output" => "4.75e-06"
      )

      expect(handler.cost_details(response)).to eq(total: 5.85e-06, input: 1.1e-06, output: 4.75e-06)
    end

    it "returns just the total when the route reports no component breakdown" do
      # Routes whose cost comes from the upstream provider rather than the gateway's
      # own calculation send the total alone.
      response = response_with("x-litellm-response-cost" => "5.6e-06")

      expect(handler.cost_details(response)).to eq(total: 5.6e-06)
    end

    it "returns nil when the gateway did not price the request" do
      # An unpriced deployment omits the header entirely rather than sending a zero,
      # so this must not be reported as a free request.
      expect(handler.cost_details(response_with({}))).to be_nil
    end

    it "returns nil rather than raising when a header is not a number" do
      expect(handler.cost_details(response_with("x-litellm-response-cost" => "free"))).to be_nil
    end

    it "ignores a component header that is not a number but keeps the total" do
      response = response_with(
        "x-litellm-response-cost" => "5.85e-06",
        "x-litellm-response-cost-input" => ""
      )

      expect(handler.cost_details(response)).to eq(total: 5.85e-06)
    end

    it "returns nil for a response carrying no HTTP metadata" do
      # Nested and locally constructed models have no last_response at all.
      expect(handler.cost_details(double("Response"))).to be_nil
      expect(handler.cost_details(double("Response", last_response: nil))).to be_nil
    end
  end

  describe "#recorded_message" do
    # Built the way the client builds a response, so the specs see the real model's fields.
    def message_with(fields)
      OpenAI::Internal::Type::Converter.coerce(
        OpenAI::Models::Chat::ChatCompletionMessage, { role: "assistant", content: "answer", refusal: nil, **fields }
      )
    end

    it "records the reasoning once, as the thinking Cerebro shows" do
      message = message_with(reasoning_content: "thinking it over",
                             provider_specific_fields: { reasoning: "thinking it over" })

      expect(handler.recorded_message(message)).to eq(
        role: :assistant, content: "answer", refusal: nil,
        thinking: [{ type: "thinking", content: "thinking it over" }]
      )
    end

    it "keeps the provider fields other than the repeated reasoning" do
      message = message_with(reasoning_content: "thinking it over",
                             provider_specific_fields: { reasoning: "thinking it over", thought_signatures: ["sig"] })

      recorded = handler.recorded_message(message)

      expect(recorded[:provider_specific_fields]).to eq(thought_signatures: ["sig"])
      expect(recorded[:thinking]).to eq([{ type: "thinking", content: "thinking it over" }])
    end

    it "takes the reasoning from the provider fields when the message has none of its own" do
      message = message_with(provider_specific_fields: { reasoning: "thinking it over" })

      recorded = handler.recorded_message(message)

      expect(recorded).not_to have_key(:provider_specific_fields)
      expect(recorded[:thinking]).to eq([{ type: "thinking", content: "thinking it over" }])
    end

    it "leaves provider reasoning that differs from the message's own where it was" do
      message = message_with(reasoning_content: "thinking it over", provider_specific_fields: { reasoning: "a summary" })

      recorded = handler.recorded_message(message)

      expect(recorded[:provider_specific_fields]).to eq(reasoning: "a summary")
      expect(recorded[:thinking]).to eq([{ type: "thinking", content: "thinking it over" }])
    end

    it "leaves the caller's message as the gateway returned it" do
      message = message_with(reasoning_content: "thinking it over",
                             provider_specific_fields: { reasoning: "thinking it over" })

      handler.recorded_message(message)[:provider_specific_fields] = "changed"

      expect(message.to_h).to eq(
        role: :assistant, content: "answer", refusal: nil, reasoning_content: "thinking it over",
        provider_specific_fields: { reasoning: "thinking it over" }
      )
    end

    it "records a message without reasoning as it came back" do
      message = message_with(reasoning_content: nil)

      expect(handler.recorded_message(message)).to eq(
        role: :assistant, content: "answer", refusal: nil, reasoning_content: nil
      )
    end

    it "does not record empty reasoning as thinking" do
      expect(handler.recorded_message(message_with(reasoning_content: ""))).not_to have_key(:thinking)
    end

    it "leaves reasoning that is not text where the provider put it" do
      structured = [{ type: "reasoning", text: "thinking it over" }]
      message = message_with(reasoning_content: structured, provider_specific_fields: { reasoning: structured })

      recorded = handler.recorded_message(message)

      expect(recorded[:reasoning_content]).to eq(structured)
      expect(recorded[:provider_specific_fields]).to eq(reasoning: structured)
      expect(recorded).not_to have_key(:thinking)
    end
  end

  describe "#chat_usage_details" do
    # Built the way the client builds a response, so the specs see the real model's fields.
    def usage_with(fields)
      OpenAI::Internal::Type::Converter.coerce(OpenAI::Models::CompletionUsage, fields)
    end

    it "carries the reasoning and cached-input breakdowns in the shape the gateway reports them" do
      usage = usage_with(
        prompt_tokens: 2434, completion_tokens: 3809, total_tokens: 6243,
        prompt_tokens_details: { cached_tokens: 1024 },
        completion_tokens_details: { reasoning_tokens: 3206 }
      )

      expect(handler.chat_usage_details(usage)).to eq(
        prompt_tokens: 2434, completion_tokens: 3809, total_tokens: 6243,
        prompt_tokens_details: { cached_tokens: 1024 },
        completion_tokens_details: { reasoning_tokens: 3206 }
      )
    end

    it "records just the totals when the response has no breakdown" do
      usage = usage_with(prompt_tokens: 10, completion_tokens: 20, total_tokens: 30, prompt_tokens_details: nil)

      expect(handler.chat_usage_details(usage)).to eq(prompt_tokens: 10, completion_tokens: 20, total_tokens: 30)
    end

    it "keeps only the counts in a breakdown" do
      usage = usage_with(
        prompt_tokens: 10, completion_tokens: 20, total_tokens: 30,
        prompt_tokens_details: { cached_tokens: nil, audio_tokens: nil },
        completion_tokens_details: { reasoning_tokens: 12, audio_tokens: nil, unexpected: "x" }
      )

      expect(handler.chat_usage_details(usage)).to eq(
        prompt_tokens: 10, completion_tokens: 20, total_tokens: 30,
        completion_tokens_details: { reasoning_tokens: 12 }
      )
    end

    it "records an Anthropic cache write once, though the gateway reports it under two names" do
      # How the gateway reports 10 uncached input tokens and a 100-token cache write: it
      # mirrors the write into both fields, and Cerebro would count each of them.
      usage = usage_with(
        prompt_tokens: 110, completion_tokens: 20, total_tokens: 130,
        prompt_tokens_details: { cached_tokens: 0, cache_write_tokens: 100, cache_creation_tokens: 100 }
      )

      expect(handler.chat_usage_details(usage)).to eq(
        prompt_tokens: 110, completion_tokens: 20, total_tokens: 130,
        prompt_tokens_details: { cached_tokens: 0, cache_write_tokens: 100 }
      )
    end

    it "records a cache write the gateway reports only under its Anthropic name" do
      usage = usage_with(
        prompt_tokens: 110, completion_tokens: 20, total_tokens: 130,
        prompt_tokens_details: { cache_creation_tokens: 100 }
      )

      expect(handler.chat_usage_details(usage)[:prompt_tokens_details]).to eq(cache_write_tokens: 100)
    end

    it "leaves out the breakdowns that overlap the others or are not part of the count" do
      usage = usage_with(
        prompt_tokens: 1079, completion_tokens: 811, total_tokens: 1890,
        prompt_tokens_details: { cached_tokens: 512, text_tokens: 1079, image_tokens: 0, initial_prompt_tokens: 900 },
        completion_tokens_details: { reasoning_tokens: 792, text_tokens: 19, audio_tokens: 0 }
      )

      expect(handler.chat_usage_details(usage)).to eq(
        prompt_tokens: 1079, completion_tokens: 811, total_tokens: 1890,
        prompt_tokens_details: { cached_tokens: 512 },
        completion_tokens_details: { reasoning_tokens: 792 }
      )
    end
  end
end
