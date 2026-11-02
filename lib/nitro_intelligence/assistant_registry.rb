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
    # Raised looking up a key `definitions` does not configure, listing the ones it does.
    class UnknownAssistantError < StandardError; end

    # @api private
    DEFINITIONS_KEY = "definitions".freeze
    # @api private
    SHARED_KEYS = %w[base_url user_id].freeze

    # @api private
    def initialize(config = {})
      @config = config.to_h.deep_stringify_keys
      @assistants = {}
    end

    # The assistant configured under `key`.
    #
    # @param key [String, Symbol]
    # @return [Assistant]
    # @raise [UnknownAssistantError] when `definitions` has no entry for `key`
    # @raise [Assistant::ConfigurationError] when the entry lacks its `api_key` or `assistant_id`
    def [](key)
      fetch(key)
    end

    # @param (see #[])
    # @return (see #[])
    # @raise (see #[])
    def fetch(key)
      key = key.to_s
      @assistants[key] ||= build(key)
    end

    # Whether `definitions` has an entry for `key`.
    #
    # @param key [String, Symbol]
    # @return [Boolean]
    def key?(key)
      definitions.key?(key.to_s)
    end

    # @return [Array<String>] the keys `definitions` configures
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

      # Blank entry values are dropped rather than merged, so a definition built from a source
      # that writes an unset field as null falls back to the shared setting instead of shadowing
      # it with nothing.
      entry = definition.to_h.deep_stringify_keys.compact_blank
      attributes = @config.slice(*SHARED_KEYS).merge(entry)
      Assistant.new(key, **attributes.symbolize_keys)
    end
  end
end
