require "spec_helper"
require "nitro_intelligence/observability/project_client_registry"

RSpec.describe NitroIntelligence::Observability::ProjectClientRegistry do
  let(:base_url) { "https://langfuse.example.com" }
  let(:registry) { described_class.new(base_url:) }
  let(:slug) { "test-project" }

  describe "#fetch" do
    context "when the project exists" do
      let(:fake_project) { double("Project", public_key: "pk_123", secret_key: "sk_123") }
      let(:fake_observability_client) { double("LangfuseExtension") }
      let(:fake_session) { double("ProjectClient") }

      before do
        allow(NitroIntelligence::Observability::Project).to receive(:find_by_slug)
          .with(slug:)
          .and_return(fake_project)

        allow(NitroIntelligence::LangfuseExtension).to receive(:new)
          .and_yield(double("Config").as_null_object)
          .and_return(fake_observability_client)

        allow(NitroIntelligence::Observability::ProjectClient).to receive(:new)
          .with(project: fake_project, observability_client: fake_observability_client)
          .and_return(fake_session)
      end

      it "builds and returns a new ProjectClient" do
        expect(registry.fetch(slug)).to eq(fake_session)
      end

      it "caches the session on subsequent calls" do
        registry.fetch(slug)

        # Calling find_by_slug should only happen once
        expect(NitroIntelligence::Observability::Project).to have_received(:find_by_slug).once

        expect(registry.fetch(slug)).to eq(fake_session)
      end

      it "configures the LangfuseExtension with the correct credentials and flush interval" do
        config_double = double("LangfuseConfig")
        expect(config_double).to receive(:public_key=).with("pk_123")
        expect(config_double).to receive(:secret_key=).with("sk_123")
        expect(config_double).to receive(:base_url=).with(base_url)
        expect(config_double).to receive(:flush_interval=).with(120)

        # FIX: Added .and_return(fake_observability_client) here so it doesn't return 120!
        expect(NitroIntelligence::LangfuseExtension).to receive(:new)
          .and_yield(config_double)
          .and_return(fake_observability_client)

        registry.fetch(slug)
      end
    end

    context "when the project does not exist" do
      before do
        allow(NitroIntelligence::Observability::Project).to receive(:find_by_slug)
          .with(slug:)
          .and_return(nil)
      end

      it "raises an error indicating the config was not found" do
        # We also need to define the error class in the test context if it's dynamically raised
        stub_const("NitroIntelligence::Observability::Project::NotFoundError", StandardError)

        expect { registry.fetch(slug) }.to raise_error(/No observability project config found for slug: test-project/)
      end
    end
  end

  describe "#shutdown_all" do
    it "calls shutdown on all cached project sessions" do
      fake_project = double("Project", public_key: "pk", secret_key: "sk")
      allow(NitroIntelligence::Observability::Project).to receive(:find_by_slug).and_return(fake_project)
      allow(NitroIntelligence::LangfuseExtension).to receive(:new).and_return(double)

      session1 = double("ProjectClient 1")
      session2 = double("ProjectClient 2")

      allow(NitroIntelligence::Observability::ProjectClient).to receive(:new).and_return(session1, session2)

      registry.fetch("project-1")
      registry.fetch("project-2")

      expect(session1).to receive(:shutdown)
      expect(session2).to receive(:shutdown)

      registry.shutdown_all
    end
  end
end
