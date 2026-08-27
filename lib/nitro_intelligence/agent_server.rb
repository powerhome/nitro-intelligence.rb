require "nitro_intelligence/assistants"
require "nitro_intelligence/deprecation"

module NitroIntelligence
  # Deprecated: the agent server is now Nitro Intelligence Assistants.
  AgentServer = ActiveSupport::Deprecation::DeprecatedConstantProxy.new(
    "NitroIntelligence::AgentServer",
    "NitroIntelligence::Assistants",
    deprecator
  )
end
