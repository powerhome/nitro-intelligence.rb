require "base64"

module NitroIntelligence
  # A file sent to or returned by a model. Callers see it as an {Image}, which documents the readers
  # they use.
  #
  # @api private
  class Media
    attr_accessor :direction, :reference_id
    attr_reader :base64, :byte_string, :file_extension, :file_type, :mime_type

    # Input should be byte string. e.g. File.binread('file.ext')
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
