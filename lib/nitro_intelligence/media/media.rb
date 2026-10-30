require "base64"

module NitroIntelligence
  # A file sent to or returned by a model.
  class Media
    # @api private
    attr_accessor :direction, :reference_id
    # @api private
    attr_reader :base64, :file_type
    # @return [String] the file's contents, as a byte string
    attr_reader :byte_string
    # @return [String, nil] the file's extension, such as `"png"`, without a dot
    attr_reader :file_extension
    # @return [String, nil] the file's MIME type, such as `"image/png"`
    attr_reader :mime_type

    # Input should be byte string. e.g. File.binread('file.ext')
    #
    # @api private
    def initialize(file)
      @base64 = Base64.strict_encode64(file)
      @byte_string = file
      @direction = "input"
      @file_extension = nil
      @file_type = nil
      @mime_type = nil
      @reference_id = nil
    end
  end
end
