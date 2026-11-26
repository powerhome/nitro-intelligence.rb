# Run only inside the public candidate container.
require "json"
require "rubygems"

path = File.expand_path("nitro_intelligence.gemspec")
exit 2 unless File.file?(path) && !File.symlink?(path)

spec = Gem::Specification.load(path)
exit 2 unless spec

dependencies = {}
spec.runtime_dependencies.each do |dep|
  exit 2 if dependencies.key?(dep.name)
  dependencies[dep.name] = dep.requirement.as_list
end
File.write(ARGV.fetch(0), JSON.generate(name: spec.name, platform: spec.platform.to_s,
                                       version: spec.version.to_s, ruby: spec.required_ruby_version.as_list,
                                       dependencies: dependencies))
