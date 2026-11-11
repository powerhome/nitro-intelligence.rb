require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)

# The client against the real inference gateway, with nothing stubbed. Billable, so not part of the
# default task; needs NIP_E2E_INFERENCE_API_KEY, and takes NIP_E2E_INFERENCE_BASE_URL to aim at a
# gateway other than the shared one.
desc "Run the end-to-end specs against the real inference gateway"
RSpec::Core::RakeTask.new(:e2e) do |task|
  task.pattern = "spec/e2e/**/*_spec.rb"
  task.rspec_opts = "--tag e2e"
end
RuboCop::RakeTask.new

# The public API is everything `.yardopts` does not hide as `@api private`, and every part of it
# carries documentation. Fails on anything undocumented and on any YARD warning, such as a `@param`
# naming an argument the method does not take.
desc "Check that the public API is fully documented"
task :yard do
  require "yard"
  require "nitro_intelligence"
  require_relative "tasks/yard_coverage"

  stats = YARD::CLI::Stats.new
  stats.run("--list-undoc", "--fail-on-warning")
  undocumented = stats.all_objects.select do |object|
    !YardCoverage.hidden?(object) && YardCoverage.undocumented?(object)
  end
  abort "yard: undocumented public API: #{undocumented.map(&:path).join(', ')}" if undocumented.any?

  missing = YardCoverage.missing_settings(NitroIntelligence::Configuration.config.keys)
  abort "yard: configuration settings missing from the reference: #{missing.join(', ')}" if missing.any?
end

task default: %i[spec rubocop yard]
