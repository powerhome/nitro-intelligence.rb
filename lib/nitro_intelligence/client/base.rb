require "nitro_intelligence/client/handlers/audio_transcription_handler"
require "nitro_intelligence/client/handlers/chat_handler"
require "nitro_intelligence/client/handlers/image_handler"

module NitroIntelligence
  module Client
    class Base
      attr_reader :client

      def initialize(client:)
        @client = client
      end

      def chat(message: "", parameters: {})
        chat_handler.create(message:, parameters:)
      end

      # Input images should be byte strings. Returns NitroIntelligence::ImageGeneration
      def generate_image(message: "", target_image: nil, reference_images: [], parameters: {})
        image_handler.create(message:, target_image:, reference_images:, parameters:)
      end

      # Audio file should be file object with extension in the filename
      # Use file_extension for now to prevent a library dependency
      def transcribe_audio(message: +"", audio_file: nil, parameters: {})
        audio_transcription_handler.create(message:, audio_file:, parameters:)
      end

    private

      def audio_transcription_handler
        @audio_transcription_handler ||= Handlers::AudioTranscriptionHandler.new(client: @client)
      end

      def chat_handler
        @chat_handler ||= Handlers::ChatHandler.new(client: @client)
      end

      def image_handler
        @image_handler ||= Handlers::ImageHandler.new(client: @client)
      end

      def method_missing(method_name, *, &)
        @client.send(method_name, *, &)
      end

      def respond_to_missing?(method_name, include_private = false)
        @client.respond_to?(method_name, include_private) || super
      end
    end
  end
end
