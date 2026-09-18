# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in branchproof.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "minitest", ">= 5.25.5", "< 6"
gem "rspec", "~> 3.13.0", require: false
rspec_core_version = ENV.fetch("BRANCHPROOF_RSPEC_CORE_VERSION", ">= 3.13.0")
gem "rspec-core", rspec_core_version, require: false

gem "rubocop", "~> 1.21"

gem "yard", "~> 0.9", require: false
gem "yard-markdown", "~> 0.9", require: false

# Rails is an optional integration-test dependency. It must never enter the
# runtime dependency set in branchproof.gemspec.
if ENV["BRANCHPROOF_RAILS_INTEGRATION"] == "1"
  gem "bootsnap", require: false
  gem "railties", "~> 8.1"
end

if ENV["BRANCHPROOF_RSPEC_RAILS_INTEGRATION"] == "1"
  gem "bootsnap", require: false
  gem "capybara", "~> 3.40", require: false
  gem "rails", "~> 8.1.0", require: false
  gem "rspec-rails", "~> 8.0", require: false
  gem "sqlite3", "~> 2.0", require: false
end
