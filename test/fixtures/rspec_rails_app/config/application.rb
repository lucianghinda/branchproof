# frozen_string_literal: true

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "active_job/railtie"
require "action_cable/engine"

module BranchproofRSpecFixture
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults 8.1
    config.eager_load = ENV["BRANCHPROOF_FIXTURE_EAGER"] == "1"
    config.enable_reloading = false
    config.active_job.queue_adapter = :async
    config.action_cable.mount_path = "/cable"
    config.action_cable.cable = { "adapter" => "async" }
    config.action_mailer.delivery_method = :test
    config.action_mailer.perform_deliveries = false
    config.autoload_paths << Rails.root.join("app")
    config.eager_load_paths << Rails.root.join("app")
  end
end
