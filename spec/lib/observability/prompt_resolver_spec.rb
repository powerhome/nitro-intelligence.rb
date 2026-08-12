require "spec_helper"
require "nitro_intelligence/observability/prompt_resolver"

RSpec.describe NitroIntelligence::Observability::PromptResolver do
  describe ".for" do
    it "resolves the selected prompt and passes the label and version through" do
      store = fake_store
      selected = fake_prompt("chat.scheduling")
      stub_lookup(store, "chat.scheduling", selected, label: "demo", version: 3)

      resolved = described_class.for(
        store:,
        parameters: {
          prompt_name: "chat.scheduling",
          prompt_fallback_name: "chat",
          prompt_label: "demo",
          prompt_version: 3,
        }
      )

      expect(resolved).to eq(selected)
    end

    it "does not look up the fallback when the selected prompt resolves" do
      store = fake_store
      stub_lookup(store, "chat.scheduling", fake_prompt("chat.scheduling"))
      stub_lookup(store, "chat", fake_prompt("chat"))

      described_class.for(store:, parameters: { prompt_name: "chat.scheduling", prompt_fallback_name: "chat" })

      expect(store).not_to have_received(:get_prompt).with(
        prompt_name: "chat", prompt_label: nil, prompt_version: nil
      )
    end

    it "returns nil when no prompt is asked for" do
      store = fake_store

      expect(described_class.for(store:, parameters: { metadata: {} })).to be_nil
      expect(store).not_to have_received(:get_prompt)
    end

    it "does not carry the requested label over to the fallback" do
      store = fake_store
      base = fake_prompt("chat")
      stub_failed_lookup(store, "chat.scheduling", "Prompt: chat.scheduling Not Found", label: "demo")
      stub_lookup(store, "chat", base)
      stub_logger

      resolved = described_class.for(
        store:,
        parameters: {
          prompt_name: "chat.scheduling",
          prompt_fallback_name: "chat",
          prompt_label: "demo",
        }
      )

      expect(resolved).to eq(base)
      expect(store).not_to have_received(:get_prompt).with(
        prompt_name: "chat", prompt_label: "demo", prompt_version: nil
      )
    end

    it "does not carry the requested version over to the fallback" do
      store = fake_store
      base = fake_prompt("chat")
      stub_failed_lookup(store, "chat.scheduling", "Prompt: chat.scheduling Not Found", version: 3)
      stub_lookup(store, "chat", base)
      stub_logger

      resolved = described_class.for(
        store:,
        parameters: {
          prompt_name: "chat.scheduling",
          prompt_fallback_name: "chat",
          prompt_version: 3,
        }
      )

      expect(resolved).to eq(base)
      expect(store).not_to have_received(:get_prompt).with(
        prompt_name: "chat", prompt_label: nil, prompt_version: 3
      )
    end

    it "gives the fallback its own label when one is asked for" do
      store = fake_store
      base = fake_prompt("chat")
      stub_failed_lookup(store, "chat.scheduling", "Prompt: chat.scheduling Not Found", label: "demo")
      stub_lookup(store, "chat", base, label: "production")
      stub_logger

      resolved = described_class.for(
        store:,
        parameters: {
          prompt_name: "chat.scheduling",
          prompt_fallback_name: "chat",
          prompt_label: "demo",
          prompt_fallback_label: "production",
        }
      )

      expect(resolved).to eq(base)
    end

    it "gives the fallback its own version when one is asked for" do
      store = fake_store
      base = fake_prompt("chat")
      stub_failed_lookup(store, "chat.scheduling", "Prompt: chat.scheduling Not Found", version: 3)
      stub_lookup(store, "chat", base, version: 7)
      stub_logger

      resolved = described_class.for(
        store:,
        parameters: {
          prompt_name: "chat.scheduling",
          prompt_fallback_name: "chat",
          prompt_version: 3,
          prompt_fallback_version: 7,
        }
      )

      expect(resolved).to eq(base)
    end

    it "looks one name up twice when the fallback asks for a different label" do
      store = fake_store
      base = fake_prompt("chat")
      stub_failed_lookup(store, "chat", "Prompt: chat Not Found", label: "demo")
      stub_lookup(store, "chat", base, label: "production")
      stub_logger

      resolved = described_class.for(
        store:,
        parameters: {
          prompt_name: "chat",
          prompt_fallback_name: "chat",
          prompt_label: "demo",
          prompt_fallback_label: "production",
        }
      )

      expect(resolved).to eq(base)
    end
  end

  describe "#prompt" do
    it "falls back to the base prompt when the selected one is missing" do
      store = fake_store
      base = fake_prompt("chat")
      stub_lookup(store, "chat.scheduling", nil)
      stub_lookup(store, "chat", base)

      expect(resolver(store, lookup("chat.scheduling"), lookup("chat")).prompt).to eq(base)
    end

    it "falls back to the base prompt when the selected lookup fails" do
      store = fake_store
      base = fake_prompt("chat")
      stub_failed_lookup(store, "chat.scheduling", "Prompt: chat.scheduling Not Found")
      stub_lookup(store, "chat", base)
      stub_logger

      expect(resolver(store, lookup("chat.scheduling"), lookup("chat")).prompt).to eq(base)
    end

    it "logs why it fell back" do
      store = fake_store
      stub_failed_lookup(store, "chat.scheduling", "Prompt: chat.scheduling Not Found")
      stub_lookup(store, "chat", fake_prompt("chat"))
      logger = stub_logger

      resolver(store, lookup("chat.scheduling"), lookup("chat")).prompt

      expect(logger).to have_received(:info).with(/chat\.scheduling.*Not Found/)
    end

    it "raises when the fallback lookup fails" do
      store = fake_store
      stub_failed_lookup(store, "chat.scheduling", "Prompt: chat.scheduling Not Found")
      stub_failed_lookup(store, "chat", "Prompt: chat Not Found")
      stub_logger

      expect { resolver(store, lookup("chat.scheduling"), lookup("chat")).prompt }
        .to raise_error(NitroIntelligence::Observability::PromptStore::ObservabilityPromptNotFoundError)
    end

    it "raises when the only prompt asked for fails" do
      store = fake_store
      stub_failed_lookup(store, "chat", "Prompt: chat Not Found")

      expect { resolver(store, lookup("chat")).prompt }
        .to raise_error(NitroIntelligence::Observability::PromptStore::ObservabilityPromptNotFoundError)
    end

    it "returns nil when the only prompt asked for is missing" do
      store = fake_store
      stub_lookup(store, "chat", nil)

      expect(resolver(store, lookup("chat")).prompt).to be_nil
    end

    it "uses the fallback when only a fallback name is given" do
      store = fake_store
      base = fake_prompt("chat")
      stub_lookup(store, "chat", base)

      expect(resolver(store, lookup(nil), lookup("chat")).prompt).to eq(base)
    end

    it "looks a repeated lookup up once, propagating its failure" do
      store = fake_store
      stub_failed_lookup(store, "chat", "Prompt: chat Not Found")

      expect { resolver(store, lookup("chat"), lookup("chat")).prompt }
        .to raise_error(NitroIntelligence::Observability::PromptStore::ObservabilityPromptNotFoundError)
    end
  end

private

  def resolver(store, *lookups)
    described_class.new(store:, lookups:)
  end

  def lookup(name, label: nil, version: nil)
    described_class::Lookup.new(name:, label:, version:)
  end

  def fake_store
    instance_spy(NitroIntelligence::Observability::PromptStore)
  end

  def fake_prompt(name)
    instance_double(NitroIntelligence::Observability::Prompt, name:)
  end

  def stub_lookup(store, name, prompt, label: nil, version: nil)
    allow(store).to receive(:get_prompt)
      .with(prompt_name: name, prompt_label: label, prompt_version: version)
      .and_return(prompt)
  end

  def stub_failed_lookup(store, name, message, label: nil, version: nil)
    allow(store).to receive(:get_prompt)
      .with(prompt_name: name, prompt_label: label, prompt_version: version)
      .and_raise(NitroIntelligence::Observability::PromptStore::ObservabilityPromptNotFoundError, message)
  end

  def stub_logger
    instance_double(Logger, info: nil, warn: nil).tap do |logger|
      allow(NitroIntelligence).to receive(:logger).and_return(logger)
    end
  end
end
