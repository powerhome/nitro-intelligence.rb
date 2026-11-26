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
    # The gateway's alias for each kind of request's default model, which it points at NIP's current
    # choice. A request that names no model asks for its kind's alias.
    DEFAULT_MODELS = {
      default_audio_transcription_model: "nip/default-audio-transcription",
      default_decision_model: "nip/default-decision",
      default_embedding_model: "nip/default-embedding",
      default_image_model: "nip/default-image",
      default_rerank_model: "nip/default-rerank",
      default_text_model: "nip/default-text",
      default_text_to_speech_model: "nip/default-text-to-speech",
    }.freeze
    REFRESH_INTERVAL = 300
    # How long to wait before asking again after the gateway failed to list its models.
    RETRY_INTERVAL = 10

    DEFAULT_MODELS.each do |default, name|
      define_method(default) { lookup_by_name(name) }
      # The alias's name, whether or not the gateway serves it to this key, so that a request for the
      # default names it when it does not.
      define_method(:"#{default}_name") { name }
    end

    # @param model_config [Hash] as {Configuration#model_config} takes it
    # @param gateway_models [GatewayModels, nil] where to find models `model_config` does not list;
    #   nil to use only those it lists
    def initialize(model_config, gateway_models = nil)
      @model_config = model_config.symbolize_keys
      warn_of_ignored_defaults
      @configured_models = (@model_config[:models] || []).map { |model_metadata| ModelFactory.build(model_metadata) }
      @gateway_models = gateway_models
      @discovered_models = []
      @next_discovery_at = nil
      @discovery_error = nil
      @listed = false
      @discovering = false
      @mutex = Mutex.new
      @discovered = ConditionVariable.new
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
      raise ArgumentError, unsupported_message(name) unless model

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

    def warn_of_ignored_defaults
      ignored = @model_config.keys & DEFAULT_MODELS.keys
      return if ignored.empty?

      NitroIntelligence.logger.warn(
        "model_config's #{ignored.join(', ')} #{ignored.one? ? 'is' : 'are'} no longer read: a request that " \
        "names no model uses the gateway's default for its kind, such as #{DEFAULT_MODELS[ignored.first]}"
      )
    end

    def unsupported_message(name)
      message = "Unsupported model: '#{name}'"
      return message unless @discovery_error

      "#{message} (the last attempt to list the inference gateway's models failed: #{@discovery_error})"
    end

    # The gateway's models, asking it for them the first time, and again when `refresh` is set and
    # the last answer is old enough. One thread asks at a time, without holding the lock while it
    # waits on the gateway. Another thread keeps using the list it has meanwhile; only one with no
    # list yet waits for the answer, which it needs as much as the thread asking.
    def discovered_models(refresh: false)
      return [] unless @gateway_models

      ask = @mutex.synchronize do
        @discovered.wait(@mutex) while @discovering && !@listed
        next false if @discovering || !discovery_due?(refresh)

        @discovering = true
      end
      discover if ask
      @mutex.synchronize { @discovered_models }
    end

    def discovery_due?(refresh)
      @next_discovery_at.nil? || (refresh && now >= @next_discovery_at)
    end

    def discover
      models = @gateway_models.fetch.filter_map { |model_metadata| build_discovered(model_metadata) }
      @mutex.synchronize do
        @discovered_models = models
        @listed = true
        @next_discovery_at = now + REFRESH_INTERVAL
        @discovery_error = nil
      end
    rescue => e
      # A gateway that cannot list its models cannot serve them either, so this only decides which
      # error a request sees: "Unsupported model" now, or the gateway's own on the request.
      error = "#{e.class}: #{e.message}"
      NitroIntelligence.logger.warn("Could not list the inference gateway's models: #{error}")
      @mutex.synchronize do
        @discovery_error = error
        @next_discovery_at = now + RETRY_INTERVAL
      end
    ensure
      @mutex.synchronize do
        @discovering = false
        @discovered.broadcast
      end
    end

    # A model the gateway does not publish enough about to use is left out, as if the gateway did
    # not serve it: a text-to-speech model with no default voice, which cannot be built, or an image
    # model with no aspect ratios or resolutions, which would refuse every request.
    def build_discovered(model_metadata)
      model = ModelFactory.build(model_metadata)
      if model.is_a?(ImageModel) && (model.aspect_ratios.blank? || model.resolutions.blank?)
        raise ArgumentError, "no aspect_ratios or resolutions"
      end

      model
    rescue ArgumentError => e
      NitroIntelligence.logger.debug("Leaving out gateway model #{model_metadata['name']}: #{e.message}")
      nil
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
