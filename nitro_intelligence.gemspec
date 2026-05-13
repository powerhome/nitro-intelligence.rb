require_relative "lib/nitro_intelligence/version"

Gem::Specification.new do |s|
  s.name        = "nitro_intelligence"
  s.version     = NitroIntelligence::VERSION
  s.authors     = ["Igor Artemenko"]
  s.email       = ["igor.artemenko@powerhrg.com"]
  s.homepage    = "https://github.com/powerhome/nitro-intelligence.rb"
  s.summary     = "Nitro Intelligence"
  s.description = "The Ruby client for Nitro Intelligence"
  s.license     = "MIT"

  s.files = Dir["{app,config,db,lib}/**/*"] + ["Rakefile", "docs/README.md"]

  s.required_ruby_version = ">= 3.3"

  s.add_dependency "activesupport", "~> 7.1"
  s.add_dependency "langfuse-rb", "0.7.0"
  s.add_dependency "mini_magick", "~> 4.10"
  s.add_dependency "openai", "~> 0.58"
  s.add_dependency "railties", "~> 7.1"

  s.metadata["rubygems_mfa_required"] = "true"
end
