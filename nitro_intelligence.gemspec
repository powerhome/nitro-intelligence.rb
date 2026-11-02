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

  # .yardopts and the guides it names ship too, so that RubyDoc.info builds the reference as
  # `bundle exec yard doc` does, without the private API.
  s.files = Dir["{app,config,db,lib}/**/*"] +
            ["Rakefile", ".yardopts", "docs/README.md", "docs/ASSISTANTS.md", "docs/CHANGELOG.md"]

  s.required_ruby_version = ">= 3.3"

  s.add_dependency "activesupport", "~> 7.1"
  s.add_dependency "langfuse-rb", "0.7.0"
  s.add_dependency "mini_magick", "~> 4.10"
  # 0.86 is the earliest version exposing `last_response` - the HTTP metadata the
  # gateway reports cost in - on every response, the binary ones text-to-speech
  # returns included. On anything older the cost is silently never recorded.
  s.add_dependency "openai", "~> 0.86"
  s.metadata["rubygems_mfa_required"] = "true"
end
