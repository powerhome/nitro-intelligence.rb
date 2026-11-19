require "json"
require "net/http"
require "uri"

module NitroIntelligence
  # The models the inference gateway serves to the configured key, as its `GET /model/info`
  # describes them. The gateway gives each model's `mode`, which decides its type, and publishes
  # what the client needs beyond that, such as an image model's aspect ratios, under
  # `model_info.nitro_intelligence`, the same on every deployment of a model group.
  #
  # @api private
  class GatewayModels
    # Raised when the gateway does not answer with its model list.
    class Error < StandardError; end

    # The model type for each LiteLLM mode the client has a handler for. Models of any other mode
    # are left out.
    TYPES = {
      "chat" => "text",
      "audio_transcription" => "audio_transcription",
      "audio_speech" => "text_to_speech",
      "embedding" => "embedding",
      "evaluation" => "decision",
      "image_generation" => "image",
      "rerank" => "rerank",
    }.freeze
    SETTINGS_KEY = "nitro_intelligence".freeze
    TIMEOUT = 5

    # @return [GatewayModels, nil] nil when there is no API key to ask the gateway with
    def self.from_config(config)
      return if config.inference_api_key.blank? || config.inference_base_url.blank?

      new(base_url: config.inference_base_url, api_key: config.inference_api_key)
    end

    def initialize(base_url:, api_key:)
      @uri = URI("#{base_url.to_s.chomp('/')}/model/info")
      @api_key = api_key
    end

    # @return [Array<Hash>] one entry per model group, as {ModelFactory.build} takes it
    # @raise [Error] when the gateway answers with anything but its model list
    def fetch
      response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https",
                                                       open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        request = Net::HTTP::Get.new(@uri)
        request["Authorization"] = "Bearer #{@api_key}"
        http.request(request)
      end
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "#{response.code} listing models: #{response.body.to_s.truncate(200)}"
      end

      parse(JSON.parse(response.body))
    rescue JSON::ParserError => e
      raise Error, "Unreadable model list: #{e.message}"
    end

  private

    # The gateway lists every deployment of a group, in the order it tries them. Their settings
    # are the same, so the first stands for the group.
    def parse(payload)
      payload.fetch("data", []).uniq { |deployment| deployment["model_name"] }.filter_map do |deployment|
        model_info = deployment["model_info"].to_h
        settings = model_info[SETTINGS_KEY].to_h
        type = settings["type"] || TYPES[model_info["mode"]]
        next unless type

        settings.merge("name" => deployment["model_name"], "type" => type)
      end
    end
  end
end
