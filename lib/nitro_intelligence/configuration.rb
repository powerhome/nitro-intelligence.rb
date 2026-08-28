require "logger"

require "nitro_intelligence/null_cache"

module NitroIntelligence
  class Configuration
    include ActiveSupport::Configurable

    config_accessor :logger, default: Logger.new($stdout)
    config_accessor :cache_provider, default: NitroIntelligence::NullCache.new
    config_accessor :current_revision, default: ""
    config_accessor :environment, default: "test"
    config_accessor :assistants_config, default: {}
    config_accessor :inference_api_key, default: ""
    config_accessor :inference_base_url, default: ""
    config_accessor :model_config, default: {}
    config_accessor :observability_base_url, default: ""
    config_accessor :observability_projects, default: []
    config_accessor :observability_user_id, default: ""

    # Deprecated: configure `assistants_config` instead. Keeps its original `{}` default through the
    # deprecation window, so a host building the hash up in place still has one to build on.
    config_accessor :agent_server_config, default: {}

    class << self
      def configure
        yield config
      end
    end
  end
end
