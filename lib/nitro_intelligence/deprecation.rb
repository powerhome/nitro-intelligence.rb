require "active_support/deprecation"

module NitroIntelligence
  class << self
    # Deprecations for names and arguments this gem no longer uses, starting with those introduced
    # while the agent server was renamed to Nitro Intelligence Assistants. All are removed in 3.0.
    def deprecator
      @deprecator ||= ActiveSupport::Deprecation.new("3.0", "Nitro Intelligence")
    end
  end
end
