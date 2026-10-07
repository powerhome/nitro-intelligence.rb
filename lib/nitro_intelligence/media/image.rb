require "base64"
require "mini_magick"
require "net/http"
require "uri"

require "nitro_intelligence/media/media"

module NitroIntelligence
  class Image < Media
    MAX_DOWNLOAD_BYTES = 50 * 1024 * 1024

    attr_reader :height, :width

    def self.from_base64(base64_string)
      # Strip data_uri from string
      base64_string = base64_string.sub(/^data:[^;]*;base64,/, "")
      byte_string = Base64.strict_decode64(base64_string)

      new(byte_string)
    end

    def self.from_url(url)
      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
        raise ArgumentError, "Generated image URLs must use HTTPS without embedded credentials."
      end

      bytes = +"".b
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 60) do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          response.value
          if response.content_length.to_i > MAX_DOWNLOAD_BYTES
            raise IOError,
                  "Generated image exceeds the download limit."
          end

          response.read_body do |chunk|
            if bytes.bytesize + chunk.bytesize > MAX_DOWNLOAD_BYTES
              raise IOError, "Generated image exceeds the download limit."
            end

            bytes << chunk
          end
        end
      end
      new(bytes)
    end

    def initialize(file)
      super

      image = MiniMagick::Image.read(StringIO.new(file))

      @mime_type = image.mime_type
      @height = image.height
      @width = image.width

      parse_mime_type
    end

  private

    def parse_mime_type
      @file_type, @file_extension = @mime_type.split("/", 2)
    end
  end
end
