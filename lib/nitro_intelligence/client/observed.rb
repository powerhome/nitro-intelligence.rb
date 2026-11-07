require "nitro_intelligence/client/handlers/observed/audio_transcription_handler"
require "nitro_intelligence/client/handlers/observed/chat_handler"
require "nitro_intelligence/client/handlers/observed/decision_handler"
require "nitro_intelligence/client/handlers/observed/embedding_handler"
require "nitro_intelligence/client/handlers/observed/image_handler"
require "nitro_intelligence/client/handlers/observed/rerank_handler"
require "nitro_intelligence/client/handlers/observed/text_to_speech_handler"
require "nitro_intelligence/observability/prompt_store"
require "nitro_intelligence/observability/upload_handler"
require "nitro_intelligence/trace"

module NitroIntelligence
  module Client
    # @api private
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

      def decision_handler
        @decision_handler ||= Handlers::Observed::DecisionHandler.new(
          base_handler: Handlers::DecisionHandler.new(client: @client), observer: @observer
        )
      end

      def embedding_handler
        @embedding_handler ||= Handlers::Observed::EmbeddingHandler.new(
          base_handler: Handlers::EmbeddingHandler.new(client: @client), observer: @observer
        )
      end

      def image_handler
        @image_handler ||= Handlers::Observed::ImageHandler.new(
          base_handler: Handlers::ImageHandler.new(client: @client), observer: @observer
        )
      end

      def rerank_handler
        @rerank_handler ||= Handlers::Observed::RerankHandler.new(
          base_handler: Handlers::RerankHandler.new(client: @client), observer: @observer
        )
      end

      def text_to_speech_handler
        @text_to_speech_handler ||= Handlers::Observed::TextToSpeechHandler.new(
          base_handler: Handlers::TextToSpeechHandler.new(client: @client), observer: @observer
        )
      end
    end
  end
end
