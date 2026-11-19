require "nitro_intelligence/models/gateway_models"
require "nitro_intelligence/models/model_factory"

module NitroIntelligence
  # The models a request may name: those `model_config` lists under `models`, and every other model
  # the gateway serves to the configured key. A model `models` lists is used exactly as listed,
  # without asking the gateway. Any other name is looked up in the gateway's model list, fetched on
  # the first such lookup and again, at most every {REFRESH_INTERVAL} seconds, when a name is not in
  # it.
  #
  # @api private
  class ModelCatalog
    DEFAULTS = %i[
      default_audio_transcription_model
      default_decision_model
      default_embedding_model
      default_image_model
      default_rerank_model
      default_text_model
      default_text_to_speech_model
    ].freeze
    REFRESH_INTERVAL = 300
    # How long to wait before asking again after the gateway failed to list its models.
    RETRY_INTERVAL = 10

    DEFAULTS.each do |default|
      define_method(default) { lookup_by_name(@model_config[default]) }
    end

    # @param model_config [Hash] as {Configuration#model_config} takes it
    # @param gateway_models [GatewayModels, nil] where to find models `model_config` does not list;
    #   nil to use only those it lists
    def initialize(model_config, gateway_models = nil)
      @model_config = model_config.symbolize_keys
      @configured_models = (@model_config[:models] || []).map { |model_metadata| ModelFactory.build(model_metadata) }
      @gateway_models = gateway_models
      @discovered_models = []
      @next_discovery_at = nil
      @mutex = Mutex.new
    end

    # Every model, including what the gateway serves, which this may ask it for.
    def models
      configured_names = @configured_models.map(&:name)
      @configured_models + discovered_models.reject { |model| configured_names.include?(model.name) }
    end

    def lookup_by_name(name)
      return if name.blank?

      @configured_models.find { |model| model.name == name } ||
        discovered_models.find { |model| model.name == name } ||
        discovered_models(refresh: true).find { |model| model.name == name }
    end

    # The named model, checked to be of the type a request needs. A model of another type
    # would fail at the gateway, or deep in a handler's own validation, with an error that
    # does not say why.
    def fetch(name, type: Model)
      model = lookup_by_name(name)
      raise ArgumentError, "Unsupported model: '#{name}'" unless model

      return model if model.is_a?(type)

      article = type.kind.start_with?(/[aeiou]/) ? "an" : "a"
      raise ArgumentError, "Model '#{name}' is not #{article} #{type.kind} model"
    end

    # Unused within the gem, which validates through #fetch, but kept for applications that check
    # whether a model is configured before offering it.
    def exists?(name)
      lookup_by_name(name).present?
    end

  private

    # The gateway's models, asking it for them the first time, and again when `refresh` is set and
    # the last answer is old enough.
    def discovered_models(refresh: false)
      return [] unless @gateway_models

      @mutex.synchronize do
        discover if @next_discovery_at.nil? || (refresh && now >= @next_discovery_at)
        @discovered_models
      end
    end

    def discover
      @discovered_models = @gateway_models.fetch.filter_map { |model_metadata| build_discovered(model_metadata) }
      @next_discovery_at = now + REFRESH_INTERVAL
    rescue => e
      # A gateway that cannot list its models cannot serve them either, so this only decides which
      # error a request sees: "Unsupported model" now, or the gateway's own on the request.
      NitroIntelligence.logger.warn("Could not list the inference gateway's models: #{e.class}: #{e.message}")
      @next_discovery_at = now + RETRY_INTERVAL
    end

    # A model the gateway does not publish enough about to use, such as a text-to-speech model with
    # no default voice, is left out, as if the gateway did not serve it.
    def build_discovered(model_metadata)
      ModelFactory.build(model_metadata)
    rescue ArgumentError => e
      NitroIntelligence.logger.debug("Leaving out gateway model #{model_metadata['name']}: #{e.message}")
      nil
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
