require "nitro_intelligence/media/media"

module NitroIntelligence
  # @api private
  class Audio < Media
    # Raised by {Client::Base#transcribe_audio} on an observed client whose project does not mask
    # content, when `audio_file` has no path. It is raised while uploading the audio to Cerebro,
    # after the gateway has transcribed it, so the transcription is lost.
    #
    # @api public
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
