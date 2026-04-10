require "spec_helper"
require "nitro_intelligence/observability/project"

RSpec.describe NitroIntelligence::Observability::Project do
  let(:fake_prompt_store) { double("PromptStore") }

  before do
    allow(NitroIntelligence::Observability::PromptStore).to receive(:new).and_return(fake_prompt_store)
  end

  describe "#initialize" do
    it "assigns attributes and initializes a PromptStore" do
      expect(NitroIntelligence::Observability::PromptStore).to receive(:new).with(
        observability_project_slug: "test-slug",
        observability_public_key: "pk_123",
        observability_secret_key: "sk_123"
      ).and_return(fake_prompt_store)

      project = described_class.new(
        slug: "test-slug",
        id: "proj_abc",
        public_key: "pk_123",
        secret_key: "sk_123",
        extra_unknown_arg: "should be ignored safely"
      )

      expect(project.slug).to eq("test-slug")
      expect(project.id).to eq("proj_abc")
      expect(project.public_key).to eq("pk_123")
      expect(project.secret_key).to eq("sk_123")
      expect(project.auth_token).to eq(Base64.strict_encode64("pk_123:sk_123"))
      expect(project.prompt_store).to eq(fake_prompt_store)
    end
  end

  describe ".find_by_slug" do
    let(:fake_config) { double("Configuration") }
    let(:configured_projects) do
      [
        { "slug" => "project-alpha", "id" => "id_a", "public_key" => "pk_a", "secret_key" => "sk_a" },
        { "slug" => "project-beta", "id" => "id_b", "public_key" => "pk_b", "secret_key" => "sk_b" },
      ]
    end

    before do
      allow(NitroIntelligence).to receive(:config).and_return(fake_config)
      allow(fake_config).to receive(:observability_projects).and_return(configured_projects)
    end

    context "when a project with the given slug exists in config" do
      it "returns a new Project instance populated with config data" do
        project = described_class.find_by_slug(slug: "project-beta")

        expect(project).to be_an_instance_of(described_class)
        expect(project.slug).to eq("project-beta")
        expect(project.id).to eq("id_b")
        expect(project.public_key).to eq("pk_b")
        expect(project.auth_token).to eq(Base64.strict_encode64("pk_b:sk_b"))
      end
    end

    context "when a project with the given slug does not exist in config" do
      it "returns nil" do
        project = described_class.find_by_slug(slug: "unknown-project")
        expect(project).to be_nil
      end
    end
  end
end
