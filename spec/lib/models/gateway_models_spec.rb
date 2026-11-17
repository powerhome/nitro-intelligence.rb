require "spec_helper"
require "webmock/rspec"
require "nitro_intelligence/models/gateway_models"

RSpec.describe NitroIntelligence::GatewayModels do
  subject(:gateway_models) { described_class.new(base_url: "https://gateway.example.com/", api_key: "secret") }

  let(:image_settings) do
    {
      "aspect_ratios" => ["1:1", "16:9"],
      "resolutions" => ["1K"],
      "omit_output_fields" => ["provider_specific_fields.thought_signatures"],
    }
  end
  let(:data) do
    [
      { "model_name" => "Qwen/Qwen3.6-35B-A3B", "model_info" => { "mode" => "chat", "access_groups" => ["approved"] } },
      { "model_name" => "Qwen/Qwen3.6-35B-A3B", "model_info" => { "mode" => "chat" } },
      {
        "model_name" => "google/gemini-3.1-flash-image",
        "model_info" => { "mode" => "image_generation", "nitro_intelligence" => image_settings },
      },
      { "model_name" => "typesafe/jev-1.14", "model_info" => { "mode" => "evaluation" } },
      { "model_name" => "some/moderation", "model_info" => { "mode" => "moderation" } },
      { "model_name" => "no/info" },
      {
        "model_name" => "custom/chat-decider",
        "model_info" => { "mode" => "chat", "nitro_intelligence" => { "type" => "decision" } },
      },
    ]
  end

  def stub_model_info(status: 200, body: { data: }.to_json)
    stub_request(:get, "https://gateway.example.com/model/info")
      .with(headers: { "Authorization" => "Bearer secret" })
      .to_return(status:, body:, headers: { "Content-Type" => "application/json" })
  end

  describe ".from_config" do
    it "builds one from the inference settings" do
      config = double(inference_api_key: "secret", inference_base_url: "https://gateway.example.com")

      expect(described_class.from_config(config)).to be_a(described_class)
    end

    it "gives nil without an API key, so the catalog never asks the gateway" do
      config = double(inference_api_key: "", inference_base_url: "https://gateway.example.com")

      expect(described_class.from_config(config)).to be_nil
    end
  end

  describe "#fetch" do
    it "lists each model group once, typed by its mode, with its client settings" do
      stub_model_info

      expect(gateway_models.fetch).to eq(
        [
          { "name" => "Qwen/Qwen3.6-35B-A3B", "type" => "text" },
          image_settings.merge("name" => "google/gemini-3.1-flash-image", "type" => "image"),
          { "name" => "typesafe/jev-1.14", "type" => "decision" },
          { "name" => "custom/chat-decider", "type" => "decision" },
        ]
      )
    end

    it "builds models the factory accepts" do
      stub_model_info

      models = gateway_models.fetch.map { |metadata| NitroIntelligence::ModelFactory.build(metadata) }

      expect(models.map(&:class)).to eq(
        [
          NitroIntelligence::TextModel,
          NitroIntelligence::ImageModel,
          NitroIntelligence::DecisionModel,
          NitroIntelligence::DecisionModel,
        ]
      )
      expect(models[1].aspect_ratios).to eq(["1:1", "16:9"])
      expect(models[1].omit_output_fields).to eq([%i[provider_specific_fields thought_signatures]])
    end

    it "raises when the gateway refuses" do
      stub_model_info(status: 401, body: '{"error":"bad key"}')

      expect { gateway_models.fetch }.to raise_error(described_class::Error, /401 listing models/)
    end

    it "raises when the gateway's answer is not JSON" do
      stub_model_info(body: "<html>")

      expect { gateway_models.fetch }.to raise_error(described_class::Error, /Unreadable model list/)
    end
  end
end
