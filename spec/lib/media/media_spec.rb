require "spec_helper"
require "base64"
require "nitro_intelligence/media/media"

RSpec.describe NitroIntelligence::Media do
  let(:byte_string) { "test_file_data" }
  let(:expected_base64) { Base64.strict_encode64(byte_string) }

  subject(:media) { described_class.new(byte_string) }

  describe "#initialize" do
    it "sets the correct attributes from the byte string" do
      expect(media.byte_string).to eq(byte_string)
      expect(media.base64).to eq(expected_base64)
    end

    it "sets default values for other attributes" do
      expect(media.direction).to eq("input")
      expect(media.file_extension).to be_nil
      expect(media.file_type).to be_nil
      expect(media.mime_type).to be_nil
      expect(media.reference_id).to be_nil
    end
  end

  describe "attr_accessors" do
    it "allows writing to direction and reference_id" do
      media.direction = "output"
      media.reference_id = "ref-12345"

      expect(media.direction).to eq("output")
      expect(media.reference_id).to eq("ref-12345")
    end
  end
end
