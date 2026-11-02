require "nitro_intelligence/client/handlers/audio_transcription_handler"
require "nitro_intelligence/client/handlers/chat_handler"
require "nitro_intelligence/client/handlers/decision_handler"
require "nitro_intelligence/client/handlers/image_handler"
require "nitro_intelligence/client/handlers/text_to_speech_handler"

module NitroIntelligence
  module Client
    # A client {Client.new} builds. Every method takes `parameters`, the request's openai-ruby
    # parameters plus this gem's own (`prompt_name`, `prompt_variables`, `trace_seed`, `metadata`,
    # `user_id` and the rest the README describes), and defaults the model to the configured
    # default for its modality.
    #
    # Each request works on a copy of the caller's `parameters`, which the handlers fill in with
    # defaults and gateway headers, so a hash passed to several requests carries nothing from one
    # request into the next.
    class Base
      # @api private
      attr_reader :client

      # @api private
      def initialize(client:)
        @client = client
      end

      # Creates a chat completion.
      #
      # @param message [String] the user's message, used when `parameters` carries no `messages`
      # @param parameters [Hash] openai-ruby's chat completion parameters, and this gem's own
      # @return [OpenAI::Models::Chat::ChatCompletion]
      # @raise [ArgumentError] when the model is not one `model_config` lists
      # @raise [Handlers::Observed::ChatHandler::ObservedChatPromptError] on an observed client, when
      #   the request carries no user message for the model to answer
      # @example
      #   client.chat(message: "Why is the sky blue?").choices.first&.message&.content
      def chat(message: "", parameters: {})
        chat_handler.create(message:, parameters: parameters.dup)
      end

      # Asks a decision model questions about some content over the gateway's System One route,
      # `POST /v1/systemone`.
      #
      # @param state [String, Hash, Array] the content the questions are about
      # @param questions [Hash] each question's name mapped to its `type` (`noul`, `choice` or
      #   `score`), `instructions` and, for `choice` and `score`, `criteria`: the options keyed by
      #   name, or the levels in order
      # @param parameters [Hash] `model`, `assets` (images `state` and the questions refer to),
      #   `metadata`, `request_options`, and this gem's own
      # @return [Decision]
      # @raise [ArgumentError] when the model is not one `model_config` lists with the type
      #   `decision`
      # @example
      #   client.decide(
      #     state: "I was charged twice.",
      #     questions: { billing: { type: "noul", instructions: "Is this message about billing?" } }
      #   ).answers[:billing].noul
      def decide(state:, questions:, parameters: {})
        decision_handler.create(state:, questions:, parameters: parameters.dup)
      end

      # Generates an image, or edits `target_image`.
      #
      # @param message [String] what to generate, or how to edit the target
      # @param target_image [String, nil] the image to edit, as a byte string
      # @param reference_images [Array<String>] further images to draw on, as byte strings
      # @param parameters [Hash] `model`, `aspect_ratio` and `resolution`, among those `model_config`
      #   lists for the model, and this gem's own
      # @return [ImageGeneration]
      # @raise [ArgumentError] when the model, aspect ratio or resolution is not one `model_config`
      #   lists
      # @example
      #   result = client.generate_image(message: "A bear installing a window")
      #   File.binwrite("bear.#{result.generated_image.file_extension}", result.generated_image.byte_string)
      def generate_image(message: "", target_image: nil, reference_images: [], parameters: {})
        image_handler.create(message:, target_image:, reference_images:, parameters: parameters.dup)
      end

      # Transcribes audio into text.
      #
      # @param message [String] a prompt to guide the transcription, such as its vocabulary or style
      # @param audio_file [File] the audio, opened in binary mode, with a filename whose extension
      #   gives its format
      # @param parameters [Hash] openai-ruby's transcription parameters, and this gem's own
      # @return [OpenAI::Models::Audio::Transcription, OpenAI::Models::Audio::TranscriptionVerbose,
      #   OpenAI::Models::Audio::TranscriptionDiarized, StringIO] whichever openai-ruby returns for
      #   the `response_format`: a `Transcription` for `json`, the default, and the response body as a
      #   StringIO for `text`, `srt` and `vtt`. An observed client records the transcription's `text`,
      #   so it supports only the formats that return an object.
      # @raise [ArgumentError] when the model is not one `model_config` lists
      # @example
      #   client.transcribe_audio(audio_file: File.open("sample.m4a", "rb")).text
      def transcribe_audio(message: +"", audio_file: nil, parameters: {})
        audio_transcription_handler.create(message:, audio_file:, parameters: parameters.dup)
      end

      # Speaks text aloud.
      #
      # @param message [String] the text to speak
      # @param parameters [Hash] openai-ruby's speech parameters, with `voice` and `response_format`
      #   among those `model_config` lists for the model, and this gem's own
      # @return [StringIO] the audio
      # @raise [ArgumentError] when the model, voice or format is not one `model_config` lists
      # @example
      #   File.binwrite("hello.mp3", client.text_to_speech(message: "Hello").string)
      def text_to_speech(message: "", parameters: {})
        text_to_speech_handler.create(message:, parameters: parameters.dup)
      end

    private

      def audio_transcription_handler
        @audio_transcription_handler ||= Handlers::AudioTranscriptionHandler.new(client: @client)
      end

      def chat_handler
        @chat_handler ||= Handlers::ChatHandler.new(client: @client)
      end

      def decision_handler
        @decision_handler ||= Handlers::DecisionHandler.new(client: @client)
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

      def text_to_speech_handler
        @text_to_speech_handler ||= Handlers::TextToSpeechHandler.new(client: @client)
      end
    end
  end
end
