require "spec_helper"
require "base64"
require "nitro_intelligence/media/image"

RSpec.describe NitroIntelligence::Image do
  let(:byte_string) { "mocked_image_bytes" }
  let(:base64_string) { Base64.strict_encode64(byte_string) }

  # Mock MiniMagick to avoid requiring a real image file during testing
  let(:mock_image) do
    instance_double(
      MiniMagick::Image,
      mime_type: "image/png",
      height: 1080,
      width: 1920
    )
  end

  before do
    allow(MiniMagick::Image).to receive(:read).and_return(mock_image)
  end

  describe "#initialize" do
    subject(:image) { described_class.new(byte_string) }

    it "inherits behavior from Media" do
      expect(image.byte_string).to eq(byte_string)
      expect(image.base64).to eq(base64_string)
      expect(image.direction).to eq("input")
    end

    it "sets attributes from the MiniMagick image" do
      expect(image.mime_type).to eq("image/png")
      expect(image.height).to eq(1080)
      expect(image.width).to eq(1920)
    end

    it "parses the mime type into file_type and file_extension" do
      expect(image.file_type).to eq("image")
      expect(image.file_extension).to eq("png")
    end
  end

  describe ".from_base64" do
    it "initializes correctly from a standard base64 string" do
      image = described_class.from_base64(base64_string)

      expect(image.byte_string).to eq(byte_string)
      expect(image.mime_type).to eq("image/png")
    end

    it "initializes correctly from a base64 string with a data URI prefix" do
      data_uri = "data:image/png;base64,#{base64_string}"
      image = described_class.from_base64(data_uri)

      expect(image.byte_string).to eq(byte_string)
      expect(image.mime_type).to eq("image/png")
    end
  end
end
