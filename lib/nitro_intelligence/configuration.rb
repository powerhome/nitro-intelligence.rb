require "logger"

require "nitro_intelligence/null_cache"

module NitroIntelligence
  # The settings {NitroIntelligence.configure} yields. Each is set on the yielded object, never on
  # this class.
  #
  # @example
  #   NitroIntelligence.configure do |config|
  #     config.logger = Rails.logger
  #     config.inference_api_key = "..."
  #   end
  class Configuration
    include ActiveSupport::Configurable

    # @!attribute [rw] logger
    #   @return [Logger] where diagnostic output goes. Defaults to standard output.
    config_accessor :logger, default: Logger.new($stdout)
    # @!attribute [rw] cache_provider
    #   @return [ActiveSupport::Cache::Store] the cache prompts are kept in, normally `Rails.cache`.
    #     Defaults to one that caches nothing.
    config_accessor :cache_provider, default: NitroIntelligence::NullCache.new
    # @!attribute [rw] current_revision
    #   @return [String] the host application's revision, such as its commit, recorded as each trace's
    #     release
    config_accessor :current_revision, default: ""
    # @!attribute [rw] environment
    #   @return [String] the runtime environment, such as `Rails.env`, recorded on traces and scores.
    #     Defaults to `"test"`.
    config_accessor :environment, default: "test"
    # @!attribute [rw] assistants_config
    #   @return [Hash] the assistants {NitroIntelligence.assistants} makes addressable by key: shared
    #     `base_url` and `user_id`, and one entry per assistant under `definitions`. Without
    #     `definitions` it is read as the keyword arguments of a single {Assistants} client. See the
    #     README's "Assistants" section.
    config_accessor :assistants_config, default: {}
    # @!attribute [rw] inference_api_key
    #   @return [String] the API key for the inference gateway
    config_accessor :inference_api_key, default: ""
    # @!attribute [rw] inference_base_url
    #   @return [String] the inference gateway's base URL. Defaults to the shared gateway.
    config_accessor :inference_base_url, default: "https://inference.powerhome.ai"
    # @!attribute [rw] inference_max_retries
    #   @return [Integer] how many times the client retries a failed request itself. Defaults to 0:
    #     see the README's "Retries and Timeouts".
    config_accessor :inference_max_retries, default: 0
    # @!attribute [rw] inference_timeout
    #   @return [Numeric, nil] the request timeout in seconds. Nil keeps openai-ruby's default of 600.
    config_accessor :inference_timeout, default: nil
    # @!attribute [rw] model_config
    #   @return [Hash] the default model for each modality (`default_text_model`,
    #     `default_audio_transcription_model`, `default_image_model`,
    #     `default_text_to_speech_model`) and the per-model settings under `models`. See the README's
    #     "Configuration".
    config_accessor :model_config, default: {}
    # @!attribute [rw] observability_base_url
    #   @return [String] Cerebro's base URL. Defaults to the shared deployment.
    config_accessor :observability_base_url, default: "https://cerebro.powerhome.ai"
    # @!attribute [rw] observability_projects
    #   @return [Array<Hash>] the credentials of each Cerebro project the host reports to, each with
    #     `slug`, `id`, `public_key` and `secret_key`
    config_accessor :observability_projects, default: []
    # @!attribute [rw] observability_user_id
    #   @return [String] the user recorded on observed traces when a request passes no `user_id`
    config_accessor :observability_user_id, default: ""

    class << self
      # @api private
      def configure
        yield config
      end
    end
  end
end
