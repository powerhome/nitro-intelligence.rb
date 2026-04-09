require "active_support"
require "active_support/core_ext"
require "base64"
require "httparty"
require "langfuse"
require "openai"

require "nitro_intelligence/agent_server"
require "nitro_intelligence/client"
require "nitro_intelligence/configuration"
require "nitro_intelligence/langfuse_extension"
require "nitro_intelligence/langfuse_tracer_provider"
require "nitro_intelligence/media/image_generation"
require "nitro_intelligence/media/upload_handler"
require "nitro_intelligence/models/model_catalog"
require "nitro_intelligence/prompt/prompt_store"

module NitroIntelligence
  OBSERVABILITY_PROJECTS_CACHE_KEY_PREFIX = "nitro_intelligence_observability_projects_".freeze
  CUSTOM_PARAMS = %i[observability_project_slug prompt_config_disabled prompt_label
                     prompt_name prompt_variables prompt_version trace_name user_id trace_seed].freeze

  class ObservabilityUnavailableError < StandardError; end
  class ObservabilityProjectNotFoundError < StandardError; end
  class ObservabilityProjectConfigNotFoundError < StandardError; end
  class LangfuseClientNotFoundError < StandardError; end

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
      @model_catalog ||= NitroIntelligence::ModelCatalog.new(configuration.model_config)
    end

    def omit_params
      (CUSTOM_PARAMS + ImageGeneration::Config::CUSTOM_PARAMS).uniq
    end

    def langfuse_clients
      if @langfuse_clients.nil?
        NitroIntelligence.logger.warn("Langfuse clients were not initialized")
        return {}
      end

      @langfuse_clients
    end

    def initialize_langfuse_clients
      @langfuse_clients = configuration.observability_projects.to_h do |project|
        key = project["slug"]

        value = LangfuseExtension.new do |config|
          config.public_key = project["public_key"]
          config.secret_key = project["secret_key"]
          config.base_url = NitroIntelligence.config.observability_base_url
          # Default flush of 60 seconds can be too quick when
          # dealing with longer responses like image gen
          config.flush_interval = 120
        end

        [key, value]
      end
    end
  end
end
