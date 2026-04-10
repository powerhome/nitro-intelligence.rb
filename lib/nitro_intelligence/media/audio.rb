require "nitro_intelligence/media/media"

module NitroIntelligence
  class Audio < Media
    class AudioFileFormatError < StandardError; end

    def initialize(file)
      # TODO: Consider a library for dealing with audio files. Dirty implementation
      raise AudioFileFormatError unless file.respond_to?(:to_path)

      file_extension = File.basename(file).split(".").last
      file = file.read
      super

      @file_extension = file_extension
      @file_type = "audio"
      @mime_type = determine_mime_type
    end

  private

    # These are supported by Langfuse
    def determine_mime_type
      ext = @file_extension.downcase

      case ext
      when "m4a", "m4b", "m4r", "m4p", "mp4"
        "audio/mp4"
      when "mp3", "mpga", "mp2", "mp1"
        "audio/mp3"
      when "wav", "wave"
        "audio/wav"
      when "webm", "weba"
        "audio/webm"
      when "ogg", "spx"
        "audio/ogg"
      when "oga"
        "audio/oga"
      when "aac"
        "audio/aac"
      when "flac"
        "audio/flac"
      when "opus"
        "audio/opus"
      else
        "audio/#{ext}"
      end
    end
  end
end
