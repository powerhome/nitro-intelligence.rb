require "active_support/deprecation"

module NitroIntelligence
  # Removed in the next major release. A Rails host has it registered with its own deprecators by
  # the Railtie, so its `config.active_support` deprecation settings (log, raise, silence) apply;
  # elsewhere it warns on stderr.
  def self.deprecator
    @deprecator ||= ActiveSupport::Deprecation.new("5.0", "nitro_intelligence")
  end
end
