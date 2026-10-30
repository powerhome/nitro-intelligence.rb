require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

# The public API is everything `.yardopts` does not hide as `@api private`, and every part of it
# carries documentation. Fails on anything undocumented and on any YARD warning, such as a `@param`
# naming an argument the method does not take.
desc "Check that the public API is fully documented"
task :yard do
  require "yard"

  stats = YARD::CLI::Stats.new
  stats.run("--list-undoc", "--fail-on-warning")
  undocumented = stats.all_objects.select { |object| object.docstring.blank? }
  abort "yard: the public API has #{undocumented.size} undocumented objects" if undocumented.any?
end

task default: %i[spec rubocop yard]
