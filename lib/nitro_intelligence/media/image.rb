require "base64"
require "mini_magick"

require "nitro_intelligence/media/media"

module NitroIntelligence
  class Image < Media
    attr_reader :height, :width

    def self.from_base64(base64_string)
      # Strip data_uri from string
      base64_string = base64_string.sub(/^data:[^;]*;base64,/, "")
      byte_string = Base64.strict_decode64(base64_string)

      new(byte_string)
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
