require "active_support"
require "active_support/core_ext"
require "base64"

require "langfuse"
require "openai"

require "nitro_intelligence/version"
require "nitro_intelligence/assistant_registry"
require "nitro_intelligence/assistants"
require "nitro_intelligence/client/base"
require "nitro_intelligence/client/client"
require "nitro_intelligence/configuration"
require "nitro_intelligence/deprecator"
require "nitro_intelligence/media/image_generation"
require "nitro_intelligence/models/model_catalog"
require "nitro_intelligence/observability/project_client_registry"
require "nitro_intelligence/reporter"

# The Ruby client for the Nitro Intelligence Platform.
#
# The public API is what `docs/README.md` and the guides it links to document, and it is the part of
# this reference not marked private. Everything else may change in any release, without notice in
# the changelog.
module NitroIntelligence
  # @!attribute [rw] configuration
  #   @api private
  #   @return [Class<Configuration>]
  mattr_accessor :configuration, default: Configuration

  class << self
    # @!method configure
    #   Sets the configuration, normally once, from an initializer.
    #   @yieldparam config [ActiveSupport::Configurable::Configuration] the settings that
    #     {Configuration} lists
    #   @return [void]
    #   @example
    #     NitroIntelligence.configure do |config|
    #       config.inference_api_key = ENV.fetch("NITRO_INTELLIGENCE_API_KEY")
    #     end
    # @!method config
    #   The current configuration.
    #   @return [ActiveSupport::Configurable::Configuration] the settings that {Configuration} lists
    # @!method logger
    #   The configured logger.
    #   @return [Logger]
    # @!method environment
    #   @api private
    delegate :configure, :config, :logger, :environment, to: :configuration

    # A registry addressable by name when `assistants_config` carries `definitions`, and the
    # single pre-registry client otherwise. The two shapes are mutually exclusive, so the
    # configuration decides which one a host gets: one that has not reshaped its config keeps
    # the client it already had.
    #
    # @return [AssistantRegistry, Assistants]
    # @raise [Assistants::ConfigurationError] without `definitions`, when `assistants_config`
    #   has no `api_key`
    # @example
    #   NitroIntelligence.assistants["candidate-concierge"].run(thread_id:, messages:)
    def assistants
      current = configuration.assistants_config.to_h.deep_stringify_keys
      return AssistantRegistry.new(current) if current.key?(AssistantRegistry::DEFINITIONS_KEY)

      Assistants.new(**current.symbolize_keys)
    end

    # @api private
    def cache
      configuration.cache_provider
    end

    # @api private
    def model_catalog
      @model_catalog ||= ModelCatalog.new(configuration.model_config)
    end

    # Each Cerebro project's client.
    #
    # @return [Observability::ProjectClientRegistry]
    def project_client_registry
      @project_client_registry ||= Observability::ProjectClientRegistry.new(
        base_url: configuration.observability_base_url
      )
    end
  end
end

require "nitro_intelligence/railtie" if defined?(Rails::Railtie)
