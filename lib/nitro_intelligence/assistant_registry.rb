require "nitro_intelligence/assistant"

module NitroIntelligence
  # Assistants addressable by name.
  #
  #   NitroIntelligence.assistants["candidate-concierge"].await_run(...)
  #
  # Built from `assistants_config`: connection settings shared by every assistant sit at the
  # top level, and each entry under `definitions` overrides them where it needs to.
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

    def [](name)
      fetch(name)
    end

    def fetch(name)
      key = name.to_s
      @assistants[key] ||= build(key)
    end

    def key?(name)
      definitions.key?(name.to_s)
    end

    def names
      definitions.keys
    end

  private

    def definitions
      @config[DEFINITIONS_KEY] || {}
    end

    def build(name)
      definition = definitions[name]

      unless definition
        raise UnknownAssistantError,
              "No assistant configured for #{name.inspect}. " \
              "Configured: #{names.sort.join(', ').presence || '(none)'}"
      end

      attributes = @config.slice(*SHARED_KEYS).merge(definition.to_h.deep_stringify_keys)
      Assistant.new(name, **attributes.symbolize_keys)
    end
  end
end
