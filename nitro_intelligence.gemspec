Gem::Specification.new do |s|
  s.name        = "nitro_intelligence"
  s.version     = "0.0.1"
  s.authors     = ["Igor Artemenko"]
  s.email       = ["igor.artemenko@powerhrg.com"]
  s.homepage    = "https://github.com/powerhome/nitro-intelligence.rb"
  s.summary     = "Nitro Intelligence"
  s.description = "The Ruby client for Nitro Intelligence"
  s.license     = "MIT"

  s.files = Dir["{app,config,db,lib}/**/*"] + ["Rakefile", "docs/README.md"]

  s.add_dependency "activesupport", "7.1.5.1"
  s.add_dependency "httparty", "~> 0.16.2"
  s.add_dependency "langfuse-rb", "0.6.0"
  s.add_dependency "mini_magick", "4.10.1"
  s.add_dependency "openai", "0.23.0"
  s.add_dependency "railties", "7.1.5.1"

  s.add_development_dependency "parser", ">= 2.5", "!= 2.5.1.1"
  s.add_development_dependency "pry", "0.14.2"
  s.add_development_dependency "pry-byebug", "3.10.1"
  s.add_development_dependency "rainbow", "2.2.2"
  s.add_development_dependency "rubocop-powerhome", "0.6.1"
  s.add_development_dependency "yard", "0.9.37"
  s.metadata["rubygems_mfa_required"] = "true"
end
