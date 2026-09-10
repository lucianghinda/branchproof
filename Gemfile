# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in branchproof.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "minitest", ">= 5.25.5", "< 6"

gem "rubocop", "~> 1.21"

# Rails is an optional integration-test dependency. It must never enter the
# runtime dependency set in branchproof.gemspec.
if ENV["BRANCHPROOF_RAILS_INTEGRATION"] == "1"
  gem "bootsnap", require: false
  gem "railties", "~> 8.1"
end
