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

require_relative "../../support/image_edit_context"

RSpec.describe NitroIntelligence::Image, "URL downloads" do
  include_context "image edit client"

  it "decodes an HTTPS image without sending gateway credentials" do
    download = stub_request(:get, "https://images.example/result.png").with do |request|
      expect(request.headers).not_to have_key("Authorization")
      true
    end.to_return(body: house_bytes, headers: { "Content-Type" => "image/png" })

    image = described_class.from_url("https://images.example/result.png")

    expect(image.byte_string).to eq(house_bytes)
    expect(image.mime_type).to eq("image/png")
    expect(download).to have_been_requested.once
  end

  ["file:///tmp/image.png", "http://images.example/result.png", "https://user:secret@images.example/result.png"].each do |url|
    it "rejects unsupported URL #{url.inspect}" do
      expect { described_class.from_url(url) }.to raise_error(ArgumentError, /HTTPS/)
    end
  end

  it "does not follow redirects" do
    stub_request(:get, "https://images.example/result.png").to_return(status: 302, headers: { "Location" => "http://localhost/image" })

    expect { described_class.from_url("https://images.example/result.png") }.to raise_error(Net::HTTPRetriableError)
  end

  it "reports failed downloads" do
    stub_request(:get, "https://images.example/result.png").to_return(status: 404)

    expect { described_class.from_url("https://images.example/result.png") }.to raise_error(Net::HTTPClientException)
  end

  it "rejects downloads exceeding the declared size limit" do
    stub_request(:get, "https://images.example/result.png").to_return(
      body: house_bytes, headers: { "Content-Length" => (described_class::MAX_DOWNLOAD_BYTES + 1).to_s }
    )

    expect { described_class.from_url("https://images.example/result.png") }.to raise_error(IOError, /download limit/)
  end

  it "enforces the size limit even without a content length" do
    stub_const("NitroIntelligence::Image::MAX_DOWNLOAD_BYTES", 4)
    stub_request(:get, "https://images.example/result.png").to_return(body: house_bytes)

    expect { described_class.from_url("https://images.example/result.png") }.to raise_error(IOError, /download limit/)
  end

  it "propagates a download timeout" do
    stub_request(:get, "https://images.example/result.png").to_raise(Net::ReadTimeout)

    expect { described_class.from_url("https://images.example/result.png") }.to raise_error(Net::ReadTimeout)
  end
end
