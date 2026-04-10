require "spec_helper"
require "base64"
require "digest"
require "time"

require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"

require "nitro_intelligence/media/upload_handler" # Adjust path as needed

RSpec.describe NitroIntelligence::UploadHandler do
  let(:observability_host) { "https://api.observability.example" }
  let(:observability_auth_token) { "secret_token_123" }
  let(:trace_id) { "trace-98765" }

  subject(:handler) { described_class.new(observability_host, observability_auth_token) }

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

  describe "#upload" do
    let(:queue) { Queue.new }
    let(:fake_time) { Time.utc(2026, 3, 13, 12, 0, 0) }

    let(:upload_url_response) do
      { "mediaId" => "media-123", "uploadUrl" => "https://s3.example/upload" }
    end

    let(:put_response) { double("HTTParty::Response", code: 200, present?: true) }
    let(:patch_response) { double("HTTParty::Response", code: 200) }

    before do
      # Freeze time so the JSON payload timestamp is predictable
      allow(Time).to receive(:now).and_return(fake_time)

      queue.push(mock_media)
      allow(mock_media).to receive(:reference_id=)

      # Mock API calls
      allow(HTTParty).to receive(:post).and_return(upload_url_response)
      allow(HTTParty).to receive(:put).and_return(put_response)
      allow(HTTParty).to receive(:patch).and_return(patch_response)
    end

    it "processes the queue, uploads the media, and assigns a reference_id" do
      # Define exactly what the JSON string should look like
      expected_post_body = {
        traceId: trace_id,
        contentType: "image/png",
        contentLength: media_bytes.bytesize,
        sha256Hash: media_sha256,
        field: "input",
      }.to_json

      # Note the explicit {} around the options to ensure RSpec treats it as an options hash
      expect(HTTParty).to receive(:post).with(
        "#{observability_host}/api/public/media",
        {
          body: expected_post_body,
          headers: anything,
        }
      )

      expect(HTTParty).to receive(:put).with(
        "https://s3.example/upload",
        {
          headers: hash_including("x-amz-checksum-sha256" => media_sha256),
          body: media_bytes,
        }
      )

      expect(mock_media).to receive(:reference_id=).with("media-123")

      results = handler.upload(trace_id, upload_queue: queue)
      expect(results).to contain_exactly(mock_media)
    end

    context "when the media already exists in Langfuse (uploadUrl is nil)" do
      let(:upload_url_response) do
        { "mediaId" => "media-123", "uploadUrl" => nil }
      end

      it "skips the PUT and PATCH requests but still assigns the reference_id" do
        expect(HTTParty).not_to receive(:put)
        expect(HTTParty).not_to receive(:patch)
        expect(mock_media).to receive(:reference_id=).with("media-123")

        handler.upload(trace_id, upload_queue: queue)
      end
    end

    context "when the upload HTTP response is not 200" do
      let(:put_response) do
        double("HTTParty::Response", code: 500, body: "Server Error", present?: true)
      end

      it "sends the error details in the PATCH request" do
        expected_patch_body = {
          uploadedAt: fake_time.utc.iso8601(6),
          uploadHttpStatus: 500,
          uploadHttpError: "Server Error",
        }.to_json

        expect(HTTParty).to receive(:patch).with(
          "#{observability_host}/api/public/media/media-123",
          {
            body: expected_patch_body,
            headers: anything,
          }
        )

        handler.upload(trace_id, upload_queue: queue)
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
