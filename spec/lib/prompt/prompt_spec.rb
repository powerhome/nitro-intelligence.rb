# spec/prompt_spec.rb
require "spec_helper"
require "nitro_intelligence/prompt/prompt"

RSpec.describe NitroIntelligence::Prompt do
  let(:text_prompt_data) do
    {
      name: "text_prompt",
      type: "text",
      prompt: "Hello, {{name}}! The year is {{year}}.",
      version: 1,
      labels: ["production"],
      tags: ["greeting"],
    }
  end
  let(:chat_prompt_data) do
    {
      name: "chat_prompt",
      type: "chat",
      prompt: [
        { role: "system", content: "You are a helpful assistant." },
        { role: "user", content: "What is {{topic}}?" },
      ],
      version: 1,
      labels: ["production"],
      tags: ["general_knowledge"],
    }
  end
  let(:text_prompt_instance) { NitroIntelligence::Prompt.new(**text_prompt_data) }
  let(:chat_prompt_instance) { NitroIntelligence::Prompt.new(**chat_prompt_data) }

  describe "#initialize" do
    it "initializes with the correct attributes" do
      expect(text_prompt_instance.name).to eq("text_prompt")
      expect(text_prompt_instance.type).to eq("text")
      expect(text_prompt_instance.prompt).to eq("Hello, {{name}}! The year is {{year}}.")
      expect(text_prompt_instance.version).to eq(1)
      expect(text_prompt_instance.labels).to eq(["production"])
      expect(text_prompt_instance.tags).to eq(["greeting"])
    end
  end

  describe "#variables" do
    context "for a text prompt" do
      it "correctly extracts variables" do
        expect(text_prompt_instance.variables).to contain_exactly(:name, :year)
      end

      it "returns an empty array if no variables are present" do
        data = text_prompt_data.merge(prompt: "A simple prompt with no variables.")
        prompt = NitroIntelligence::Prompt.new(**data)
        expect(prompt.variables).to eq([])
      end
    end

    context "for a chat prompt" do
      it "correctly extracts variables from multiple messages" do
        expect(chat_prompt_instance.variables).to contain_exactly(:topic)
      end
    end
  end

  describe "#compile" do
    context "for a text prompt" do
      it "replaces variables with the provided replacements" do
        compiled_content = text_prompt_instance.compile(name: "Alice", year: 2025)
        expect(compiled_content).to eq("Hello, Alice! The year is 2025.")
      end

      it "leaves unmatched variables as is" do
        compiled_content = text_prompt_instance.compile(name: "Bob")
        expect(compiled_content).to eq("Hello, Bob! The year is {{year}}.")
      end
    end

    context "for a chat prompt" do
      it "replaces variables in all message contents" do
        compiled_content = chat_prompt_instance.compile(topic: "Ruby on Rails")
        expect(compiled_content).to eq([
                                         { role: "system", content: "You are a helpful assistant." },
                                         { role: "user", content: "What is Ruby on Rails?" },
                                       ])
      end

      it "leaves unmatched variables in message contents" do
        compiled_content = chat_prompt_instance.compile(topic: "Machine Learning")
        expect(compiled_content).to eq([
                                         { role: "system", content: "You are a helpful assistant." },
                                         { role: "user", content: "What is Machine Learning?" },
                                       ])
      end
    end
  end

  describe "#interpolate" do
    let(:messages) { [{ role: "user", content: "Please summarize this text." }] }

    context "for a text prompt" do
      it "prepends the compiled prompt as a system message" do
        interpolated_messages = text_prompt_instance.interpolate(messages:, variables: { name: "World", year: 2024 })
        expect(interpolated_messages.first).to eq({ role: "system", content: "Hello, World! The year is 2024." })
        expect(interpolated_messages.last).to eq({ role: "user", content: "Please summarize this text." })
      end
    end

    context "for a chat prompt" do
      it "prepends the compiled prompt to the messages array" do
        interpolated_messages = chat_prompt_instance.interpolate(messages:, variables: { topic: "AI" })
        expect(interpolated_messages).to eq([
                                              { role: "system", content: "You are a helpful assistant." },
                                              { role: "user", content: "What is AI?" },
                                              { role: "user", content: "Please summarize this text." },
                                            ])
      end
    end
  end
end
