require_relative "e2e_helper"

RSpec.describe NitroIntelligence::Reporter, :e2e do
  subject(:reporter) { described_class.new(observability_project_slug: E2eHelpers::OBSERVABILITY_PROJECT_SLUG) }

  let(:dataset_name) { "nitro-intelligence.rb e2e" }
  let(:run_id) { "#{ENV.fetch('GITHUB_RUN_ID', 'local')}-#{SecureRandom.hex(4)}" }
  # An item of each run's own, so runs that overlap cannot read back each other's, deleted afterwards
  # so the dataset does not grow.
  let(:item_id) { "nitro-intelligence.rb-e2e-#{run_id}" }

  after { cerebro.delete_dataset_item(item_id) }

  describe "#create_dataset_item" do
    it "stores the item in the project's dataset" do
      cerebro.ensure_dataset(dataset_name)

      response = reporter.create_dataset_item(
        {
          id: item_id, datasetName: dataset_name, input: { message: "Reply with pong.", run: run_id },
          expectedOutput: "pong", metadata: e2e_metadata
        }
      )

      expect(response).to be_a(Net::HTTPSuccess)
      expect(cerebro.dataset_item(item_id)).to include(
        "id" => item_id, "datasetName" => dataset_name, "input" => { "message" => "Reply with pong.", "run" => run_id },
        "expectedOutput" => "pong", "status" => "ACTIVE"
      )
    end

    it "raises when Cerebro does not store the item" do
      expect { reporter.create_dataset_item({ datasetName: "nitro-intelligence.rb e2e: no such dataset", input: {} }) }
        .to raise_error(NitroIntelligence::Reporter::DatasetItemError, /\A4\d\d creating dataset item/)
    end
  end
end
