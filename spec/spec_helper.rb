ENV["RAILS_ENV"] ||= "test"

RSPEC_ROOT = File.expand_path("../", __dir__)
require "active_support/all"
require "nitro_intelligence"

# The deprecated methods are still specified; their warnings are asserted where they are raised.
NitroIntelligence.deprecator.behavior = :silence

Dir[File.join(__dir__, "support/**/*.rb")].each { |file| require file }
