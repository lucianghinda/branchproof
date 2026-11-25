# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in branchproof.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

if ENV["BRANCHPROOF_MINITEST_VERSION"]
  gem "minitest", ENV.fetch("BRANCHPROOF_MINITEST_VERSION")
else
  gem "minitest", ">= 5.25.5", "< 6"
end
gem "rspec", "~> 3.13.0", require: false
rspec_core_version = ENV.fetch("BRANCHPROOF_RSPEC_CORE_VERSION", ">= 3.13.0")
gem "rspec-core", rspec_core_version, require: false

gem "rubocop", "~> 1.21"

gem "yard", "~> 0.9", require: false
gem "yard-markdown", "~> 0.9", require: false

# Bootsnap is an optional integration-test dependency. It must never enter the
# runtime dependency set in branchproof.gemspec.
if ENV["BRANCHPROOF_RAILS_INTEGRATION"] == "1" || ENV["BRANCHPROOF_RSPEC_RAILS_INTEGRATION"] == "1" ||
   ENV["BRANCHPROOF_BOOTSNAP_VERSION"]
  gem "bootsnap", ENV.fetch("BRANCHPROOF_BOOTSNAP_VERSION", ">= 0"), require: false
end

# Rails is an optional integration-test dependency. It must never enter the
# runtime dependency set in branchproof.gemspec.
gem "railties", "~> 8.1" if ENV["BRANCHPROOF_RAILS_INTEGRATION"] == "1"

if ENV["BRANCHPROOF_RSPEC_RAILS_INTEGRATION"] == "1"
  gem "capybara", "~> 3.40", require: false
  gem "rails", "~> 8.1.0", require: false
  gem "rspec-rails", "~> 8.0", require: false
  gem "sqlite3", "~> 2.0", require: false
end
