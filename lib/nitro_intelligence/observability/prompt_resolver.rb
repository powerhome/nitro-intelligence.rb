require "nitro_intelligence/observability/prompt_store"

module NitroIntelligence
  module Observability
    # Resolves a managed prompt from the lookups a request asks for, most specific first. A lookup that is
    # missing -- or that fails -- yields to the next; the last one's failure propagates.
    class PromptResolver
      # One prompt lookup: the name asked for, at a label or a version.
      Lookup = Data.define(:name, :label, :version)

      def self.for(store:, parameters:)
        new(store: store, lookups: lookups_for(parameters)).prompt
      end

      # The fallback names its own label and version and inherits neither: a version is minted per prompt,
      # and a label the requested prompt carries need not exist on the fallback at all.
      def self.lookups_for(parameters)
        [
          Lookup.new(
            name: parameters[:prompt_name],
            label: parameters[:prompt_label],
            version: parameters[:prompt_version]
          ),
          Lookup.new(
            name: parameters[:prompt_fallback_name],
            label: parameters[:prompt_fallback_label],
            version: parameters[:prompt_fallback_version]
          ),
        ]
      end

      def initialize(store:, lookups:)
        @store = store
        @lookups = lookups.select { |lookup| lookup.name.present? }.uniq
      end

      def prompt
        *optional, final = @lookups
        return nil if final.nil?

        optional.each do |lookup|
          resolved = fetch_optional(lookup)
          return resolved if resolved
        end

        fetch(final)
      end

    private

      def fetch(lookup)
        @store.get_prompt(
          prompt_name: lookup.name,
          prompt_label: lookup.label,
          prompt_version: lookup.version
        )
      end

      def fetch_optional(lookup)
        fetch(lookup)
      rescue => e
        NitroIntelligence.logger.info(
          "#{self.class} #{e} - Falling back to the next prompt name after a failed lookup: #{lookup.name}"
        )
        nil
      end
    end
  end
end
