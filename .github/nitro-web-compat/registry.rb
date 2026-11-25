require "digest"
require "fileutils"
require "webrick"

# Bundler reads compact-index metadata over loopback in the offline runner.
# Preserve every published choice reachable from the candidate. For all other
# registry gems the lockfile already records the version(s), platform(s) and edges.
module LocalRegistry
  def self.write_records(catalog, specs)
    FileUtils.mkdir_p("registry/info")
    Dir.children(catalog).each { |name| File.symlink(File.join(catalog, name), "registry/info/#{name}") }
    specs.group_by(&:name).each do |name, variants|
      raise "Invalid lockfile name" unless name.match?(/\A\w[\w.-]*\z/)

      file = "registry/info/#{name}"
      next if File.exist?(file)

      lines = variants.map do |spec|
        version = spec.full_name.delete_prefix("#{name}-")
        deps = spec.dependencies.map { |dep| "#{dep.name}:#{dep.requirement.as_list.join('&')}" }
        "#{version} #{deps.join(',')}|"
      end
      File.write(file, "---\n#{lines.join("\n")}\n")
    end
  end

  def self.write_versions
    File.open("registry/versions", "w") do |versions|
      versions.puts "---"
      Dir["registry/info/*"].each do |file|
        contents = File.read(file)
        records = contents.split("---\n", 2).last.to_s.lines.map { |line| line.split.first }
        next if records.empty?

        # The compact-index v2 wire format specifies MD5 for this cache validator.
        # Both ends run in the same offline container. No authentication depends on it.
        # bearer:disable ruby_lang_weak_hash_md
        versions.puts "#{File.basename(file)} #{records.join(',')} #{Digest::MD5.hexdigest(contents)}"
      end
    end
  end

  def self.serve(catalog, specs)
    write_records(catalog, specs)
    write_versions
    server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0, DocumentRoot: File.expand_path("registry"),
                                     AccessLog: [], Logger: WEBrick::Log.new(File::NULL))
    thread = Thread.new { server.start }
    begin
      yield "http://127.0.0.1:#{server.config.fetch(:Port)}/"
    ensure
      server.shutdown
      thread.join
    end
  end
end
