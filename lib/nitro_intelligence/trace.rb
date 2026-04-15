module NitroIntelligence
  module Trace
    def self.create_id(seed:)
      Langfuse::TraceId.create(seed:)
    end
  end
end
