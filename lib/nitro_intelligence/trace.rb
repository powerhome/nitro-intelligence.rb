module NitroIntelligence
  module Trace
    def self.create_id(seed: SecureRandom.uuid, length: 32)
      Digest::SHA256.hexdigest(seed)[0, length]
    end
  end
end
