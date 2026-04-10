require "base64"
require "digest"
require "httparty"
require "time"

module NitroIntelligence
  module Observability
    class UploadHandler
      def initialize(auth_token:)
        @host = NitroIntelligence.config.observability_base_url
        @auth_token = auth_token
        @uploaded_media = []
      end

      def replace_base64_with_media_references(payload)
        # Make it easier to lookup message style image_urls
        media_lookup = @uploaded_media.index_by { |image| "data:#{image.mime_type};base64,#{image.base64}" }

        replace_base64_image_url = ->(node) do
          case node
          when Hash
            url_key = if node.key?(:url)
                        :url
                      else
                        (node.key?("url") ? "url" : nil)
                      end

            if url_key
              url_value = node[url_key]

              # Replace base64 strings if they match with our uploaded media
              if (media = media_lookup[url_value])
                # Overwrite base64 string with Langfuse media ref
                # This *should* be rendering inline in the gui
                # https://github.com/langfuse/langfuse/issues/4555
                # https://github.com/langfuse/langfuse/issues/5030
                node[url_key] = "@@@langfuseMedia:type=#{media.mime_type}|id=#{media.reference_id}|source=bytes@@@"
              # Sometimes models can generate unwanted images that will not have a reference
              # these untracked base64 strings can easily push 4.5mb Langfuse limit
              elsif url_value.is_a?(String) && url_value.start_with?("data:")
                node[url_key] = "[Discarded media]"
              end
            end

            node.each_value { |val| replace_base64_image_url.call(val) }

          when Array
            node.each { |val| replace_base64_image_url.call(val) }
          end
        end

        replace_base64_image_url.call(payload)

        payload
      end

      def upload(trace_id, upload_queue: Queue.new)
        until upload_queue.empty?
          media = upload_queue.pop

          content_length = media.byte_string.bytesize
          content_sha256 = Base64.strict_encode64(Digest::SHA256.digest(media.byte_string))

          # returns {"mediaId" -> "", "uploadUrl" => ""}
          upload_url_response = get_upload_url({
                                                 traceId: trace_id,
                                                 contentType: media.mime_type,
                                                 contentLength: content_length,
                                                 sha256Hash: content_sha256,
                                                 field: media.direction,
                                               })

          # NOTE: uploadUrl is None if the file is stored in Langfuse already
          # there is no need to upload it again.
          upload_response = upload_media(
            upload_url_response["mediaId"],
            upload_url_response["uploadUrl"],
            media.mime_type,
            content_sha256,
            media.byte_string
          )

          associate_media(upload_url_response["mediaId"], upload_response) if upload_response.present?

          media.reference_id = upload_url_response["mediaId"]
          @uploaded_media.append(media)
        end

        @uploaded_media
      end

    private

      def get_upload_url(request_body)
        HTTParty.post(
          "#{@host}/api/public/media",
          body: request_body.to_json,
          headers: {
            "Content-Type" => "application/json",
            "Authorization" => "Basic #{@auth_token}",
          }
        )
      end

      def associate_media(media_id, upload_response)
        request_body = {
          uploadedAt: Time.now.utc.iso8601(6),
          uploadHttpStatus: upload_response.code,
          uploadHttpError: upload_response.code == 200 ? nil : upload_response.body,
        }

        HTTParty.patch(
          "#{@host}/api/public/media/#{media_id}",
          body: request_body.to_json,
          headers: {
            "Content-Type" => "application/json",
            "Authorization" => "Basic #{@auth_token}",
          }
        )
      end

      def upload_media(media_id, upload_url, content_type, content_sha256, content_bytes)
        if media_id.present? && upload_url.present?
          return HTTParty.put(
            upload_url,
            headers: {
              "Content-Type" => content_type,
              "x-amz-checksum-sha256" => content_sha256,
            },
            body: content_bytes
          )
        end

        nil
      end
    end
  end
end
