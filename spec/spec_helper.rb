ENV["RAILS_ENV"] ||= "test"

RSPEC_ROOT = File.expand_path("../", __dir__)
require "active_support/all"
require "nitro_intelligence"

Dir[File.join(__dir__, "support/**/*.rb")].each { |file| require file }
