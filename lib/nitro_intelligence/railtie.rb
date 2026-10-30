require "nitro_intelligence/deprecator"

module NitroIntelligence
  # @api private
  class Railtie < ::Rails::Railtie
    initializer "nitro_intelligence.deprecator" do |app|
      app.deprecators[:nitro_intelligence] = NitroIntelligence.deprecator
    end
  end
end
