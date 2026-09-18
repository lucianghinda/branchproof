# frozen_string_literal: true

require "rubygems/version"

# Rails policy validation intentionally stays in one adapter-neutral module.
# rubocop:disable Metrics/ModuleLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

module Branchproof
  # Boots the selected Rails application after Branchproof's load hook is active.
  module RailsSupport
    SUPPORTED_RAILS = Gem::Version.new("8.1").freeze
    SUPPORTED_RSPEC_RAILS_MAJOR = 8
    SUPPORTED_CAPYBARA_DRIVER = "rack_test"

    class Error < StandardError; end

    module_function

    # Boot the Rails application for the native Minitest adapter.
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

    # Require the application and validate the process-wide Rails policy.
    # This method is public so adapter-specific helpers can own the remaining
    # test framework setup while sharing the exact same Rails boot checks.
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

    # Validate the seam after an RSpec Rails helper has loaded. RSpec owns
    # requiring rspec/rails and configuring its example groups; this method
    # only checks that that setup is attached to the same, already-validated
    # Rails application.
    def validate_rspec!(project:)
      kind = project[:kind] || project["kind"]
      return nil if kind.to_s != "rails" && !defined?(Rails)
      raise Error, "Rails was loaded for a non-Rails project" if kind.to_s != "rails"

      validate_application!
      raise Error, "RSpec Rails was not loaded; require rspec/rails from rails_helper" unless defined?(RSpec::Rails)

      expected_root = File.expand_path(project.fetch(:root).to_s)
      actual_root = Rails.root && File.expand_path(Rails.root.to_s)
      if actual_root != expected_root
        raise Error,
              "Rails application root #{actual_root.inspect} does not match project root #{expected_root.inspect}"
      end

      rails_metadata = metadata.merge(rspec_rails_version: rspec_rails_version)
      validate_version_tuple!(rails_metadata)
      install_rspec_driver_guard!
      rails_metadata
    end

    def install_rspec_driver_guard!
      return unless defined?(Capybara::Session)
      return if Capybara::Session.instance_variable_defined?(:@branchproof_driver_guard)

      support = self
      Capybara::Session.prepend(Module.new do
        define_method(:initialize) do |driver, *args, &block|
          begin
            support.validate_rspec_driver!(driver: driver)
          rescue Branchproof::RailsSupport::Error => e
            adapter = (Branchproof::RSpecAdapter.active_adapter if defined?(Branchproof::RSpecAdapter))
            adapter ? adapter.reject_execution!(e.message) : raise
          end
          super(driver, *args, &block)
        end
      end)
      Capybara::Session.instance_variable_set(:@branchproof_driver_guard, true)
    end

    # RSpec Rails invokes this at example execution time, before the example
    # can ask Capybara to launch a browser. The adapter converts this explicit
    # rejection into an incomplete/error execution result.
    def validate_rspec_driver!(example_metadata)
      metadata = example_metadata.respond_to?(:to_h) ? example_metadata.to_h : {}
      driver = metadata[:driver] || metadata["driver"]
      threaded = metadata[:threaded] || metadata["threaded"] || metadata[:parallel] || metadata["parallel"]
      unsupported = metadata[:js] == true || metadata["js"] == true || threaded ||
                    (driver && driver.to_s != SUPPORTED_CAPYBARA_DRIVER)
      return true unless unsupported

      selected = driver || (threaded ? "threaded" : "browser")
      raise Error, "unsupported RSpec driver #{selected.inspect}; only in-process rack_test is supported"
    end

    def validate_version_tuple!(rails_metadata)
      rails_version = Gem::Version.new(rails_metadata.fetch(:rails_version).to_s)
      ruby_version = Gem::Version.new(rails_metadata.fetch(:ruby_version).to_s)
      rspec_version = Gem::Version.new(rails_metadata.fetch(:rspec_rails_version).to_s)
      return true if rails_version.segments.first(2) == SUPPORTED_RAILS.segments.first(2) &&
                     ruby_version.segments.first(2) == [3, 4] &&
                     rspec_version.segments.first == SUPPORTED_RSPEC_RAILS_MAJOR

      raise Error,
            "unsupported Rails/Ruby/RSpec Rails tuple: Rails #{rails_version}, Ruby #{ruby_version}, " \
            "RSpec Rails #{rspec_version} (supported Rails 8.1, Ruby 3.4.x, RSpec Rails 8.x)"
    end

    def rspec_rails_version
      require "rspec/rails/version" if defined?(RSpec::Rails) && !defined?(RSpec::Rails::Version::STRING)
      return RSpec::Rails::Version::STRING if defined?(RSpec::Rails::Version::STRING)
      return RSpec::Rails::VERSION if defined?(RSpec::Rails::VERSION)
      return Gem.loaded_specs.fetch("rspec-rails").version.to_s if Gem.loaded_specs.key?("rspec-rails")

      "unknown"
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
        ruby_version: RUBY_VERSION,
        environment: Rails.env.to_s,
        reloading: reloading_enabled?(rails_application.config),
        serial_policy: { mode: "single_process", workers: 1, parallel_workers: 1 } }
    end
  end
end
# rubocop:enable Metrics/ModuleLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
