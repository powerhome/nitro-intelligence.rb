require "nitro_intelligence/client/handlers/observed/audio_transcription_handler"
require "nitro_intelligence/client/handlers/observed/chat_handler"
require "nitro_intelligence/client/handlers/observed/image_handler"
require "nitro_intelligence/observability/prompt_store"
require "nitro_intelligence/observability/upload_handler"
require "nitro_intelligence/trace"

module NitroIntelligence
  module Client
    class Observed < Base
      def initialize(client:, observer:)
        super(client:)
        @observer = observer
      end

    private

      def chat_handler
        @chat_handler ||= Handlers::Observed::ChatHandler.new(
          base_handler: Handlers::ChatHandler.new(client: @client), observer: @observer
        )
      end

      def audio_transcription_handler
        @audio_transcription_handler ||=
          Handlers::Observed::AudioTranscriptionHandler.new(
            base_handler: Handlers::AudioTranscriptionHandler.new(client: @client), observer: @observer
          )
      end

      def image_handler
        @image_handler ||= Handlers::Observed::ImageHandler.new(
          base_handler: Handlers::ImageHandler.new(client: @client), observer: @observer
        )
      end
    end
  end
end
