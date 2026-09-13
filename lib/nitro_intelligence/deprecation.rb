require "active_support/deprecation"

module NitroIntelligence
  class << self
    # Deprecations introduced while the agent server was renamed to Nitro Intelligence Assistants.
    # The names they cover are removed in 3.0.
    def deprecator
      @deprecator ||= ActiveSupport::Deprecation.new("3.0", "Nitro Intelligence")
    end
  end
end
