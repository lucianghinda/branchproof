# frozen_string_literal: true

module Branchproof
  # Boots the selected Rails application after Branchproof's load hook is active.
  module RailsSupport
    class Error < StandardError; end

    module_function

    def boot(project:)
      environment = environment_path(project)
      raise Error, "Rails project is missing #{environment}" unless File.file?(environment)

      boot_environment(environment)
      metadata
    rescue Error
      raise
    rescue LoadError => e
      raise Error, "Rails boot could not load #{e.path || e.message}: #{e.message}"
    rescue StandardError => e
      raise Error, "Rails boot failed: #{e.class}: #{e.message}"
    end

    def environment_path(project)
      root = File.expand_path(project.fetch(:root).to_s)
      File.join(root, "config", "environment.rb")
    end

    def boot_environment(environment)
      require environment
      validate_application!
      require "rails/test_help"
      validate_application!
    end

    def validate_application!
      application = rails_application
      validate_test_environment

      reloading = reloading_enabled?(application.config)
      raise Error, "Rails reloading is unsupported; set config.enable_reloading = false" if reloading

      nil
    end

    def rails_application
      if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
        application = Rails.application
        return application unless application.respond_to?(:initialized?) && !application.initialized?
      end

      raise Error, "Rails boot did not initialize Rails.application"
    end

    def validate_test_environment
      return if Rails.respond_to?(:env) && Rails.env.to_s == "test"

      actual = Rails.respond_to?(:env) ? Rails.env : "unknown"
      raise Error, "Rails boot must use the test environment (got #{actual})"
    end

    def reloading_enabled?(config)
      return config.enable_reloading if config.respond_to?(:enable_reloading)
      return !config.cache_classes if config.respond_to?(:cache_classes)

      false
    end

    def metadata
      { rails_version: Rails::VERSION::STRING,
        serial_policy: { mode: "single_process", workers: 1, parallel_workers: 1 } }
    end
  end
end
