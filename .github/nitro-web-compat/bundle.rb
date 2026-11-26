module SyntheticBundle
  # Every gemspec Bundler loads is generated here. Filenames are sequential and
  # every data literal (including private component names) is quoted by Ruby.
  def self.write_stub(index, spec)
    lines = [
      "Gem::Specification.new do |s|",
      "  s.name = #{spec.name.dump}",
      "  s.version = #{spec.version.to_s.dump}",
      "  s.platform = #{spec.platform.to_s.dump}",
      "  s.required_ruby_version = #{spec.required_ruby_version.as_list.inspect}",
      '  s.summary = "Compatibility check"',
      '  s.authors = ["CI"]',
    ]
    spec.dependencies.each do |dep|
      args = [dep.name, *dep.requirement.as_list].map(&:dump)
      lines << "  s.add_dependency #{args.join(', ')}"
    end
    File.write("stubs/#{index}.gemspec", (lines << "end").join("\n"))
  end

  def self.write_stubs(local, candidate, pinned)
    Dir.mkdir("stubs")
    local.each_with_index do |spec, index|
      spec.dependencies.map! { |dep| dep.name == candidate.name ? pinned : dep }
      write_stub(index, spec.name == candidate.name ? candidate : spec)
    end
  end

  def self.write_gemfile(roots, local_names, registry)
    public_roots = []
    stub_roots = []
    roots.each do |name, dep|
      args = [name, *dep.requirement.as_list].map(&:dump)
      list = local_names.include?(name) ? stub_roots : public_roots
      list << "gem #{args.join(', ')}"
    end
    gemfile = ["source #{registry.dump}", *public_roots, 'path "stubs" do', *stub_roots, "end"]
    File.write("Gemfile", "#{gemfile.join("\n")}\n")
  end

  def self.prepare(lock, candidate, registry)
    name = candidate.name
    pinned = Gem::Dependency.new(name, candidate.version)
    local = lock.specs.select do |spec|
      spec.name == name || spec.source.is_a?(Bundler::Source::Path) # includes Git
    end
    write_stubs(local, candidate, pinned)
    # Bundler keeps platform-excluded roots in DEPENDENCIES even when they have no locked spec.
    roots = lock.dependencies.slice(*lock.specs.map(&:name))
    roots[name] = pinned
    write_gemfile(roots, local.map(&:name), registry)
  end
end
