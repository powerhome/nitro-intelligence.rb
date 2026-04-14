require "active_support"
require "active_support/core_ext"
require "base64"

require "langfuse"
require "openai"

require "nitro_intelligence/version"
require "nitro_intelligence/agent_server"
require "nitro_intelligence/client/base"
require "nitro_intelligence/client/client"
require "nitro_intelligence/configuration"
require "nitro_intelligence/media/image_generation"
require "nitro_intelligence/models/model_catalog"
require "nitro_intelligence/observability/project_client_registry"
require "nitro_intelligence/reporter"

module NitroIntelligence
  mattr_accessor :configuration, default: Configuration

  class << self
    delegate :configure, :config, :logger, :environment, to: :configuration

    def agent_server
      AgentServer.new(**configuration.agent_server_config.symbolize_keys)
    end

    def cache
      configuration.cache_provider
    end

    def model_catalog
      @model_catalog ||= ModelCatalog.new(configuration.model_config)
    end

    def project_client_registry
      @project_client_registry ||= Observability::ProjectClientRegistry.new(
        base_url: configuration.observability_base_url
      )
    end
  end
end
