require "nitro_intelligence/deprecator"

module NitroIntelligence
  class Railtie < ::Rails::Railtie
    initializer "nitro_intelligence.deprecator" do |app|
      app.deprecators[:nitro_intelligence] = NitroIntelligence.deprecator
    end
  end
end
