require "nitro_intelligence/assistant"

module NitroIntelligence
  # Assistants addressable by name.
  #
  #   NitroIntelligence.assistants["candidate-concierge"].await_run(...)
  #
  # Built from `assistants_config`: connection settings shared by every assistant sit at the
  # top level, and each entry under `definitions` overrides them where it needs to. The key an
  # entry is filed under is what it is looked up by, distinct from any `name` it carries.
  #
  #   {
  #     "base_url" => "https://nip-assistants.example.com",
  #     "user_id" => "nitro-web",
  #     "definitions" => {
  #       "candidate-concierge" => { "graph_id" => "react-agent" },
  #     },
  #   }
  class AssistantRegistry
    class UnknownAssistantError < StandardError; end

    DEFINITIONS_KEY = "definitions".freeze
    SHARED_KEYS = %w[base_url user_id].freeze

    def initialize(config = {})
      @config = config.to_h.deep_stringify_keys
      @assistants = {}
    end

    def [](key)
      fetch(key)
    end

    def fetch(key)
      key = key.to_s
      @assistants[key] ||= build(key)
    end

    def key?(key)
      definitions.key?(key.to_s)
    end

    def keys
      definitions.keys
    end

  private

    def definitions
      @config[DEFINITIONS_KEY] || {}
    end

    def build(key)
      definition = definitions[key]

      unless definition
        raise UnknownAssistantError,
              "No assistant configured for #{key.inspect}. " \
              "Configured: #{keys.sort.join(', ').presence || '(none)'}"
      end

      attributes = @config.slice(*SHARED_KEYS).merge(definition.to_h.deep_stringify_keys)
      Assistant.new(key, **attributes.symbolize_keys)
    end
  end
end
