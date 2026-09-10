# frozen_string_literal: true

require "rails"
require "action_controller/railtie"
require "active_support/core_ext/integer/time"

module BranchproofRailsFixture
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults 8.1
    config.eager_load = ENV["BRANCHPROOF_FIXTURE_EAGER"] == "1"
    config.enable_reloading = false
    config.autoload_paths << Rails.root.join("app")
    config.eager_load_paths << Rails.root.join("app")
  end
end
