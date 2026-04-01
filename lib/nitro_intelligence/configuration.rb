require "logger"

require "nitro_intelligence/null_cache"

module NitroIntelligence
  class Configuration
    include ActiveSupport::Configurable

    config_accessor :logger, default: Logger.new($stdout)
    config_accessor :cache_provider, default: NitroIntelligence::NullCache.new
    config_accessor :environment, default: "test"
    config_accessor :agent_server_config, default: {}
    config_accessor :inference_api_key, default: ""
    config_accessor :inference_base_url, default: ""
    config_accessor :model_config, default: {}
    config_accessor :observability_base_url, default: ""
    config_accessor :observability_projects, default: []

    class << self
      def configure
        yield config
      end
    end
  end
end
