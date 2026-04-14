require "spec_helper"
require "nitro_intelligence/client/factory"

RSpec.describe NitroIntelligence::Client::Factory do
  let(:fake_registry) { double("ProjectClientRegistry") }
  let(:fake_logger) { instance_double(Logger, warn: nil) }

  before do
    allow(NitroIntelligence.config).to receive(:inference_api_key).and_return("fake-key")
    allow(NitroIntelligence.config).to receive(:inference_base_url).and_return("https://fake.url")

    allow(NitroIntelligence).to receive(:project_client_registry).and_return(fake_registry)
    allow(NitroIntelligence).to receive(:logger).and_return(fake_logger)
  end

  describe "#build" do
    context "when observability_project_slug is not present" do
      it "returns a Base client" do
        factory = described_class.new(observability_project_slug: nil)
        expect(factory.build).to be_an_instance_of(NitroIntelligence::Client::Base)
      end
    end

    context "when observability_project_slug is present" do
      let(:slug) { "test-slug" }

      it "returns an Observed client when project session exists" do
        fake_session = double("ProjectClient")
        allow(fake_registry).to receive(:fetch).with(slug).and_return(fake_session)
        allow(NitroIntelligence::Client::Observers::LangfuseObserver).to receive(:new).and_return(double)

        factory = described_class.new(observability_project_slug: slug)
        expect(factory.build).to be_an_instance_of(NitroIntelligence::Client::Observed)
      end

      it "rescues errors, logs a warning, and falls back to Base client when session is missing" do
        allow(fake_registry).to receive(:fetch).with(slug).and_return(nil)

        expect(fake_logger).to receive(:warn).with(/Falling back to base client/)

        factory = described_class.new(observability_project_slug: slug)
        expect(factory.build).to be_an_instance_of(NitroIntelligence::Client::Base)
      end
    end
  end
end
