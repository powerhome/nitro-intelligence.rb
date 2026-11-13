ENV["RAILS_ENV"] ||= "test"

RSPEC_ROOT = File.expand_path("../", __dir__)
require "active_support/all"
require "nitro_intelligence"

# The deprecated methods are still specified; their warnings are asserted where they are raised.
NitroIntelligence.deprecator.behavior = :silence

Dir[File.join(__dir__, "support/**/*.rb")].each { |file| require file }

# The end-to-end specs in spec/e2e make billable calls to a real gateway, so a run that also loads
# other specs, as a bare `rspec` does, leaves them out. Naming only e2e files runs them, and so does
# `--tag e2e`, which is what `rake e2e` passes.
E2E_SPECS = File.join(__dir__, "e2e", "").freeze

RSpec.configure do |config|
  config.filter_run_excluding :e2e unless config.files_to_run.all? { |file| file.start_with?(E2E_SPECS) }
end
