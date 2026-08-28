require "active_support"
require "active_support/core_ext"
require "base64"

require "langfuse"
require "openai"

require "nitro_intelligence/version"
require "nitro_intelligence/agent_server"
require "nitro_intelligence/assistants"
require "nitro_intelligence/client/base"
require "nitro_intelligence/client/client"
require "nitro_intelligence/configuration"
require "nitro_intelligence/deprecation"
require "nitro_intelligence/media/image_generation"
require "nitro_intelligence/models/model_catalog"
require "nitro_intelligence/observability/project_client_registry"
require "nitro_intelligence/reporter"

module NitroIntelligence
  mattr_accessor :configuration, default: Configuration

  class << self
    delegate :configure, :config, :logger, :environment, to: :configuration

    def assistants
      Assistants.new(**assistants_config.symbolize_keys)
    end

    # Deprecated: use `NitroIntelligence.assistants`.
    def agent_server
      deprecator.warn("`NitroIntelligence.agent_server` is deprecated. Use `NitroIntelligence.assistants` instead.")
      assistants
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

  private

    # A host that has migrated is left alone, so a stale `agent_server_config` cannot override the
    # configuration it was replaced by.
    def assistants_config
      current_config = configuration.assistants_config
      legacy_config = configuration.agent_server_config
      return current_config if current_config.present? || legacy_config.blank?

      deprecator.warn(
        "`agent_server_config` is deprecated. Configure `assistants_config` instead."
      )
      legacy_config
    end
  end
end
