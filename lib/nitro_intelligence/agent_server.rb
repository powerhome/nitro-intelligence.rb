require "active_support/deprecation/constant_accessor"
require "nitro_intelligence/assistants"
require "nitro_intelligence/deprecation"

module NitroIntelligence
  include ActiveSupport::Deprecation::DeprecatedConstantAccessor

  # Deprecated: the agent server is now Nitro Intelligence Assistants. Resolved through
  # `const_missing` so that the old name returns the real class rather than a stand-in for it,
  # keeping `is_a?`, `===`, `rescue` and the nested error constants working on upgrade.
  deprecate_constant :AgentServer, "NitroIntelligence::Assistants", deprecator:
end
