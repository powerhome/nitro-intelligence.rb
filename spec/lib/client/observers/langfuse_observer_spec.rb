require "spec_helper"
require "nitro_intelligence/client/observers/langfuse_observer"

RSpec.describe NitroIntelligence::Client::Observers::LangfuseObserver do
  let(:fake_observability_client) { double("ObservabilityClient") }
  let(:fake_project_client) { double("ProjectClient", observability_client: fake_observability_client) }
  let(:observer) { described_class.new(project_client: fake_project_client) }

  let(:fake_generation) do
    double(
      "Generation",
      update_trace: nil,
      update: nil,
      :model= => nil,
      :usage_details= => nil,
      :input= => nil,
      :output= => nil
    )
  end

  let(:fake_config) do
    double("Configuration", observability_user_id: "global-user-123", current_revision: "rev-v1.0")
  end

  before do
    allow(NitroIntelligence).to receive(:configuration).and_return(fake_config)
    allow(NitroIntelligence).to receive(:environment).and_return(:test)
    allow(Langfuse).to receive(:propagate_attributes).and_yield
    allow(fake_observability_client).to receive(:observe).and_yield(fake_generation)
  end

  describe "#observe" do
    let(:default_args) do
      {
        type: :generation,
        parameters: { model: "gpt-4", metadata: {} },
        trace_name: "test-trace",
      }
    end

    it "wraps execution in Langfuse propagation and observability blocks" do
      expect(Langfuse).to receive(:propagate_attributes).with(
        user_id: "global-user-123",
        metadata: {}
      ).and_yield

      expect(fake_observability_client).to receive(:observe).with(
        "chat-completion",
        as_type: :generation,
        trace_id: nil,
        environment: "test",
        model: "gpt-4",
        metadata: {}
      ).and_yield(fake_generation)

      expect(fake_generation).to receive(:update_trace).with(name: "test-trace", release: "rev-v1.0")

      result = observer.observe("chat-completion", **default_args) do |generation|
        expect(generation).to eq(fake_generation)
        ["success_result", nil]
      end

      expect(result).to eq("success_result")
    end

    it "passes custom metadata from parameters to Langfuse" do
      custom_metadata = { custom_key: "value", another_key: "another_value" }

      expect(Langfuse).to receive(:propagate_attributes).with(
        user_id: "global-user-123",
        metadata: { custom_key: "value", another_key: "another_value" }
      ).and_yield

      expect(fake_observability_client).to receive(:observe).with(
        "chat-completion",
        as_type: :generation,
        trace_id: nil,
        environment: "test",
        model: "gpt-4",
        metadata: { custom_key: "value", another_key: "another_value" }
      ).and_yield(fake_generation)

      expect(fake_generation).to receive(:update_trace).with(name: "test-trace", release: "rev-v1.0")

      result = observer.observe(
        "chat-completion",
        **default_args, parameters: { model: "gpt-4", metadata: custom_metadata }
      ) do |_generation|
        ["success_result", nil]
      end

      expect(result).to eq("success_result")
    end

    it "generates a trace_id if trace_seed is provided" do
      allow(NitroIntelligence::Trace).to receive(:create_id).with(seed: "seed-456").and_return("generated-trace-id")

      expect(fake_observability_client).to receive(:observe).with(
        anything,
        hash_including(trace_id: "generated-trace-id")
      ).and_yield(fake_generation)

      observer.observe("chat-completion", **default_args, parameters: { trace_seed: "seed-456", metadata: {} }) do
        ["result", nil]
      end
    end

    context "when a prompt is provided" do
      let(:fake_prompt) { double("Prompt", name: "onboarding-prompt", version: "v2") }

      it "updates metadata and generation with prompt information" do
        expect(Langfuse).to receive(:propagate_attributes).with(
          hash_including(
            metadata: hash_including(
              prompt_name: "onboarding-prompt",
              prompt_version: "v2"
            )
          )
        ).and_yield

        # FIX: Added explicit curly braces to expect a positional hash instead of kwargs
        expect(fake_generation).to receive(:update).with({ prompt: { name: "onboarding-prompt", version: "v2" } })

        observer.observe("chat-completion", **default_args, prompt: fake_prompt) do
          ["result", nil]
        end
      end
    end

    context "when trace attributes are returned from the block" do
      let(:fake_model_catalog) { double("ModelCatalog") }
      let(:fake_model_config) { double("ModelConfig", omit_output_fields: nil) }

      before do
        allow(NitroIntelligence).to receive(:model_catalog).and_return(fake_model_catalog)
        allow(fake_model_catalog).to receive(:lookup_by_name).with("gpt-4").and_return(fake_model_config)
      end

      it "updates generation attributes with trace values" do
        trace_attrs = {
          model: "gpt-4",
          input: "input text",
          output: "output text",
          usage_details: { total_tokens: 42 },
        }

        expect(fake_generation).to receive(:model=).with("gpt-4")
        expect(fake_generation).to receive(:usage_details=).with({ total_tokens: 42 })
        expect(fake_generation).to receive(:input=).with("input text")
        expect(fake_generation).to receive(:output=).with("output text")
        expect(fake_generation).to receive(:update_trace).with(input: "input text", output: "output text")

        observer.observe("chat-completion", **default_args) do
          ["result", trace_attrs]
        end
      end

      context "when model specifies output fields to omit (truncation)" do
        let(:fake_model_config) do
          double("ModelConfig", omit_output_fields: [%i[data image_base64], [:choices, 0, :heavy_data]])
        end

        it "mutates the output hash by replacing specified nested keys with '[Truncated...]'" do
          original_output = {
            data: { image_base64: "very_long_string", metadata: "keep me" },
            choices: [{ heavy_data: "too_much", ok_data: "fine" }],
          }

          expected_truncated_output = {
            data: { image_base64: "[Truncated...]", metadata: "keep me" },
            choices: [{ heavy_data: "[Truncated...]", ok_data: "fine" }],
          }

          expect(fake_generation).to receive(:output=).with(expected_truncated_output)
          expect(fake_generation).to receive(:update_trace).with(input: "input text", output: expected_truncated_output)

          observer.observe("chat-completion", **default_args) do
            ["result", { model: "gpt-4", input: "input text", output: original_output }]
          end
        end
      end
    end
  end
end
