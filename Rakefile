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
  output = `yard stats --list-undoc 2>&1`
  puts output
  abort "yard: stats failed" unless Process.last_status.success?
  abort "yard: the public API has undocumented objects" unless output.include?("100.00% documented")
  abort "yard: fix the warnings above" if output.include?("[warn]")
end

task default: %i[spec rubocop yard]
