require "spec_helper"
require "base64"
require "digest"
require "time"
require "json"
require "webmock/rspec"

require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"

require "nitro_intelligence/observability/upload_handler"

RSpec.describe NitroIntelligence::Observability::UploadHandler do
  let(:host) { "https://api.observability.example" }
  let(:auth_token) { "secret_token_123" }
  let(:trace_id) { "trace-98765" }

  subject(:handler) { described_class.new(auth_token:) }

  let(:media_bytes) { "fake_image_data" }
  let(:media_base64) { Base64.strict_encode64(media_bytes) }
  let(:media_sha256) { Base64.strict_encode64(Digest::SHA256.digest(media_bytes)) }

  let(:mock_media) do
    instance_double(
      "Media",
      byte_string: media_bytes,
      base64: media_base64,
      mime_type: "image/png",
      direction: "input",
      reference_id: "media-123"
    )
  end

  let(:expected_api_headers) do
    {
      "Content-Type" => "application/json",
      "Authorization" => "Basic #{auth_token}",
    }
  end

  before do
    config_mock = double("Config", observability_base_url: host)
    allow(NitroIntelligence).to receive(:config).and_return(config_mock)
  end

  describe "#upload" do
    let(:queue) { Queue.new }
    let(:fake_time) { Time.utc(2026, 3, 13, 12, 0, 0) }

    let(:upload_url_response_body) do
      { "mediaId" => "media-123", "uploadUrl" => "https://s3.example/upload" }.to_json
    end

    before do
      allow(Time).to receive(:now).and_return(fake_time)

      queue.push(mock_media)
      allow(mock_media).to receive(:reference_id=)

      stub_request(:post, "#{host}/api/public/media")
        .to_return(status: 200, body: upload_url_response_body, headers: { "Content-Type" => "application/json" })

      stub_request(:put, "https://s3.example/upload")
        .to_return(status: 200, body: "", headers: {})

      stub_request(:patch, "#{host}/api/public/media/media-123")
        .to_return(status: 200, body: "", headers: {})
    end

    it "processes the queue, uploads the media, and assigns a reference_id" do
      expected_post_body = {
        traceId: trace_id,
        contentType: "image/png",
        contentLength: media_bytes.bytesize,
        sha256Hash: media_sha256,
        field: "input",
      }.to_json

      results = handler.upload(trace_id, upload_queue: queue)

      expect(
        a_request(:post, "#{host}/api/public/media")
          .with(body: expected_post_body, headers: expected_api_headers)
      ).to have_been_made

      expect(
        a_request(:put, "https://s3.example/upload")
          .with(headers: { "x-amz-checksum-sha256" => media_sha256 })
      ).to have_been_made

      expect(mock_media).to have_received(:reference_id=).with("media-123")
      expect(results).to contain_exactly(mock_media)
    end

    it "exposes the uploaded media via the #uploaded_media reader" do
      handler.upload(trace_id, upload_queue: queue)

      expect(handler.uploaded_media).to contain_exactly(mock_media)
    end

    context "when the media already exists in Langfuse (uploadUrl is nil)" do
      let(:upload_url_response_body) do
        { "mediaId" => "media-123", "uploadUrl" => nil }.to_json
      end

      it "skips the PUT and PATCH requests but still assigns the reference_id" do
        handler.upload(trace_id, upload_queue: queue)

        expect(a_request(:put, "https://s3.example/upload")).not_to have_been_made
        expect(a_request(:patch, "#{host}/api/public/media/media-123")).not_to have_been_made
        expect(mock_media).to have_received(:reference_id=).with("media-123")
      end
    end

    context "when the upload HTTP response is not 200" do
      before do
        stub_request(:put, "https://s3.example/upload")
          .to_return(status: 500, body: "Server Error", headers: {})
      end

      it "sends the error details in the PATCH request" do
        expected_patch_body = {
          uploadedAt: fake_time.utc.iso8601(6),
          uploadHttpStatus: 500,
          uploadHttpError: "Server Error",
        }.to_json

        handler.upload(trace_id, upload_queue: queue)

        expect(
          a_request(:patch, "#{host}/api/public/media/media-123")
            .with(body: expected_patch_body, headers: expected_api_headers)
        ).to have_been_made
      end
    end
  end

  describe "#replace_base64_with_media_references" do
    before do
      # Pre-populate the handler's state as if upload() was already called
      handler.instance_variable_set(:@uploaded_media, [mock_media])
    end

    it "replaces base64 strings of tracked media with a Langfuse media reference (Symbol Keys)" do
      payload = { url: "data:image/png;base64,#{media_base64}" }

      result = handler.replace_base64_with_media_references(payload)

      expect(result[:url]).to eq("@@@langfuseMedia:type=image/png|id=media-123|source=bytes@@@")
    end

    it "replaces base64 strings of tracked media with a Langfuse media reference (String Keys)" do
      payload = { "url" => "data:image/png;base64,#{media_base64}" }

      result = handler.replace_base64_with_media_references(payload)

      expect(result["url"]).to eq("@@@langfuseMedia:type=image/png|id=media-123|source=bytes@@@")
    end

    it "replaces untracked base64 image strings with [Discarded media]" do
      payload = { url: "data:image/jpeg;base64,untracked_base64_string_here" }

      result = handler.replace_base64_with_media_references(payload)

      expect(result[:url]).to eq("[Discarded media]")
    end

    it "leaves standard HTTP URLs untouched" do
      payload = { url: "https://example.com/image.png" }

      result = handler.replace_base64_with_media_references(payload)

      expect(result[:url]).to eq("https://example.com/image.png")
    end

    it "recursively traverses complex, deeply nested payloads" do
      payload = {
        messages: [
          {
            role: "user",
            content: [
              { type: "text", text: "Look at this image" },
              {
                type: "image_url",
                image_url: { url: "data:image/png;base64,#{media_base64}" },
              },
              {
                type: "image_url",
                image_url: { url: "data:image/jpeg;base64,untracked_gibberish" },
              },
            ],
          },
        ],
      }

      result = handler.replace_base64_with_media_references(payload)

      content = result[:messages].first[:content]

      expect(content[0][:text]).to eq("Look at this image")
      expect(content[1][:image_url][:url]).to eq("@@@langfuseMedia:type=image/png|id=media-123|source=bytes@@@")
      expect(content[2][:image_url][:url]).to eq("[Discarded media]")
    end
  end
end
