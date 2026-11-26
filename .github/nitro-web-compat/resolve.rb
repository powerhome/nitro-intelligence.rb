# Run in an empty directory under the consumer's exact Ruby and Bundler.
require "json"
require "English"
gem "bundler", ENV.fetch("BUNDLER_VERSION") if ENV.key?("BUNDLER_VERSION")
require "bundler"
require_relative "bundle"

module NitroWebCompat
  GEM_NAME = "nitro_intelligence".freeze
  REGISTRY = "https://rubygems.org/".freeze
  SECTIONS = ["PATH", "GIT", "GEM", "PLATFORMS", "DEPENDENCIES", "CHECKSUMS", "RUBY VERSION", "BUNDLED WITH"].freeze

  def self.candidate_spec(data)
    Gem::Specification.new do |spec|
      spec.name = GEM_NAME
      spec.version = data.fetch("version")
      spec.required_ruby_version = data.fetch("ruby")
      data.fetch("dependencies").each { |name, requirements| spec.add_dependency(name, *requirements) }
    end
  end

  def self.dependency_tree(specs)
    by_name = specs.group_by(&:name)
    seen = Set.new
    queue = [GEM_NAME]
    until queue.empty?
      name = queue.pop
      next unless seen.add?(name)

      by_name.fetch(name, []).each { |spec| queue.concat(spec.dependencies.map(&:name)) }
    end
    seen
  end

  def self.unrelated_versions(specs, movable)
    specs.reject { |spec| movable.include?(spec.name) }.group_by(&:name)
         .transform_values { |variants| variants.map(&:version).uniq.sort }
  end

  def self.read_snapshot(snapshot)
    raise "Wrong Ruby" unless File.read(File.join(snapshot, ".ruby-version")).strip == RUBY_VERSION

    File.write("Gemfile", "")
    original = File.read(File.join(snapshot, "Gemfile.lock"))
    # Reject plugin sources before the parser can try to load a plugin.
    sections = Bundler::LockfileParser.sections_in_lockfile(original)
    raise "Unsupported lockfile" unless (sections - SECTIONS).empty?

    lock = Bundler::LockfileParser.new(original)
    raise "Wrong Bundler" unless lock.bundler_version.to_s == Bundler::VERSION

    registries = lock.sources.grep(Bundler::Source::Rubygems).flat_map(&:remotes).map(&:to_s)
    raise "Unsupported registry" unless registries == [REGISTRY]

    lock
  end

  def self.verify_candidate(result, candidate)
    matches = result.specs.select { |spec| spec.name == GEM_NAME }
    raise "Wrong candidate" unless matches.one?

    spec = matches.first
    raise "Wrong source" unless spec.source.is_a?(Bundler::Source::Path)
    raise "Wrong version" unless spec.version == candidate.version

    expected = candidate.dependencies.sort_by(&:name)
    raise "Wrong dependencies" unless spec.dependencies.sort_by(&:name) == expected
  end

  def self.check_result(original, candidate)
    result = Bundler::LockfileParser.new(File.read("Gemfile.lock"))
    verify_candidate(result, candidate)
    movable = dependency_tree(original.specs) | dependency_tree(result.specs)
    unrelated_versions(original.specs, movable) == unrelated_versions(result.specs, movable) ? 0 : 6
  end

  def self.run(snapshot, candidate)
    lock = read_snapshot(snapshot)
    raise "Candidate missing from baseline" unless lock.specs.any? { |spec| spec.name == candidate.name }

    # The lock format omits the Ruby requirement of a same-version path gem.
    return 6 unless candidate.required_ruby_version.satisfied_by?(Gem.ruby_version)

    SyntheticBundle.prepare(lock, candidate, REGISTRY)
    return $CHILD_STATUS.exitstatus || 1 unless system(Gem.ruby, Gem.bin_path("bundler", "bundle", Bundler::VERSION),
                                                       "lock", "--update", GEM_NAME)

    check_result(lock, candidate)
  end
end

if $PROGRAM_NAME == __FILE__
  snapshot, metadata = ARGV
  candidate = NitroWebCompat.candidate_spec(JSON.parse(File.read(metadata)))
  exit NitroWebCompat.run(snapshot, candidate)
end
