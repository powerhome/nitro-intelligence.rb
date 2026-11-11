ENV["RAILS_ENV"] ||= "test"

RSPEC_ROOT = File.expand_path("../", __dir__)
require "active_support/all"
require "nitro_intelligence"

# The deprecated methods are still specified; their warnings are asserted where they are raised.
NitroIntelligence.deprecator.behavior = :silence

Dir[File.join(__dir__, "support/**/*.rb")].each { |file| require file }

# The end-to-end specs in spec/e2e make billable calls to a real gateway. `rake e2e` runs them with
# `--tag e2e`, which lifts this exclusion.
RSpec.configure do |config|
  config.filter_run_excluding :e2e
end
