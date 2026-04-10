# spec/prompt_store_spec.rb
require "spec_helper"
require "nitro_intelligence/observability/prompt_store"
require "webmock/rspec"

RSpec.describe NitroIntelligence::Observability::PromptStore do
  let(:observability_project_slug) { "test-project" }
  let(:observability_public_key) { "public_key" }
  let(:observability_secret_key) { "secret_key" }
  let(:observability_host) { "https://test.observability.ai" }
  let(:prompt_store) do
    NitroIntelligence::Observability::PromptStore.new(
      observability_project_slug:,
      observability_public_key:,
      observability_secret_key:
    )
  end

  # Mock external dependencies
  before do
    allow(NitroIntelligence.config).to receive(:observability_base_url).and_return(observability_host)
    allow(NitroIntelligence).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(NitroIntelligence).to receive(:logger).and_return(double(info: nil, warn: nil))
  end

  let(:prompt_api_response) do
    {
      name: "example_prompt",
      type: "text",
      prompt: "This is a prompt with a {{variable}}.",
      version: 1,
      labels: ["production"],
      tags: ["test"],
    }.to_json
  end
  let(:prompt_version_cache_key) { "nitro_intelligence_observability_prompts_test-project_example_prompt_1" }
  let(:prompt_label_cache_key) { "nitro_intelligence_observability_prompts_test-project_example_prompt_production" }

  describe "#get_prompt" do
    context "when a version is specified" do
      it "fetches the prompt by version" do
        stub_request(:get, "#{observability_host}/api/public/v2/prompts/example_prompt?version=1")
          .to_return(status: 200, body: prompt_api_response)

        prompt = prompt_store.get_prompt(prompt_name: "example_prompt", prompt_version: 1)
        expect(prompt).to be_a(NitroIntelligence::Observability::Prompt)
        expect(prompt.version).to eq(1)
      end

      it "raises an error if the prompt is not found" do
        stub_request(:get, "#{observability_host}/api/public/v2/prompts/example_prompt?version=1")
          .to_return(status: 404, body: "Not Found")

        expect { prompt_store.get_prompt(prompt_name: "example_prompt", prompt_version: 1) }
          .to raise_error(NitroIntelligence::Observability::PromptStore::ObservabilityPromptNotFoundError)
      end
    end

    context "when a label is specified" do
      it "fetches the prompt by label" do
        stub_request(:get, "#{observability_host}/api/public/v2/prompts/example_prompt?label=production")
          .to_return(status: 200, body: prompt_api_response)

        prompt = prompt_store.get_prompt(prompt_name: "example_prompt", prompt_label: "production")
        expect(prompt).to be_a(NitroIntelligence::Observability::Prompt)
        expect(prompt.labels).to include("production")
      end

      it "defaults to the 'production' label if no label or version is specified" do
        stub_request(:get, "#{observability_host}/api/public/v2/prompts/example_prompt?label=production")
          .to_return(status: 200, body: prompt_api_response)

        prompt = prompt_store.get_prompt(prompt_name: "example_prompt")
        expect(prompt).to be_a(NitroIntelligence::Observability::Prompt)
        expect(prompt.labels).to include("production")
      end
    end
  end

  describe "caching behavior" do
    it "returns the cached prompt if available" do
      # Simulate a cache hit
      NitroIntelligence.cache.write(prompt_label_cache_key, JSON.parse(prompt_api_response, symbolize_names: true))

      # We don't expect an HTTP request to be made
      expect(HTTParty).not_to receive(:get)

      prompt = prompt_store.get_prompt(prompt_name: "example_prompt", prompt_label: "production")
      expect(prompt).to be_a(NitroIntelligence::Observability::Prompt)
    end

    it "fetches from the API and writes to cache on a cache miss" do
      expect(NitroIntelligence.cache).to receive(:write).with(prompt_version_cache_key, anything, expires_in: nil).and_call_original
      expect(NitroIntelligence.cache).to receive(:write).with(prompt_label_cache_key, anything, expires_in: 5.minutes).and_call_original
      expect(NitroIntelligence.cache).to receive(:write).with("#{prompt_label_cache_key}_rolling", anything, expires_in: nil).and_call_original

      stub_request(:get, "#{observability_host}/api/public/v2/prompts/example_prompt?label=production")
        .to_return(status: 200, body: prompt_api_response)

      prompt = prompt_store.get_prompt(prompt_name: "example_prompt", prompt_label: "production")
      expect(prompt).to be_a(NitroIntelligence::Observability::Prompt)
    end

    it "uses rolling cache on API failure" do
      # Seed the rolling cache
      rolling_prompt_data = JSON.parse(prompt_api_response, symbolize_names: true).merge(version: 999)
      NitroIntelligence.cache.write("#{prompt_label_cache_key}_rolling", rolling_prompt_data)

      # Stub a failed HTTP request
      stub_request(:get, "#{observability_host}/api/public/v2/prompts/example_prompt?label=production")
        .to_return(status: 500, body: "Internal Server Error")

      prompt = prompt_store.get_prompt(prompt_name: "example_prompt", prompt_label: "production")
      expect(prompt).to be_a(NitroIntelligence::Observability::Prompt)
      expect(prompt.version).to eq(999)
    end
  end
end
