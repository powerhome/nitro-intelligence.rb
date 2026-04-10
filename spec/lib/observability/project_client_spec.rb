require "spec_helper"
require "base64"
require "nitro_intelligence/observability/project_client"

RSpec.describe NitroIntelligence::Observability::ProjectClient do
  let(:auth_token) { Base64.strict_encode64("pk_test:sk_test") }
  let(:fake_project) { double("Project", public_key: "pk_test", secret_key: "sk_test", auth_token:) }
  let(:fake_observability_client) { double("LangfuseExtension", shutdown: nil) }

  describe "#initialize" do
    it "sets attributes and builds an upload handler with a Base64 auth token" do
      session = described_class.new(
        project: fake_project,
        observability_client: fake_observability_client
      )

      expect(session.project).to eq(fake_project)
      expect(session.observability_client).to eq(fake_observability_client)
    end
  end

  describe "#shutdown" do
    it "delegates the shutdown command to the observability client" do
      session = described_class.new(
        project: fake_project,
        observability_client: fake_observability_client
      )

      expect(fake_observability_client).to receive(:shutdown)
      session.shutdown
    end
  end
end
