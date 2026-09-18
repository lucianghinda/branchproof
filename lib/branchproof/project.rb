# frozen_string_literal: true

module Branchproof
  # Resolves the project policy used by the isolated analysis worker.
  class Project
    MODES = %w[auto ruby rails].freeze
    FRAMEWORKS = %w[auto minitest rspec].freeze
    RAILS_ENVIRONMENT = {
      "RAILS_ENV" => "test",
      "RACK_ENV" => "test",
      "PARALLEL_WORKERS" => "1",
      "DISABLE_BOOTSNAP" => "1",
      "DISABLE_SPRING" => "1"
    }.freeze

    def initialize(root:, mode: "auto", framework: "auto")
      @root = File.expand_path(root)
      @mode = mode.to_s
      @framework = framework.to_s
      raise ArgumentError, "project must be auto, ruby, or rails" unless MODES.include?(@mode)
      raise ArgumentError, "framework must be auto, minitest, or rspec" unless FRAMEWORKS.include?(@framework)

      validate_root!
      resolve_framework!
    end

    def to_h
      {
        kind: kind,
        root: @root,
        framework: framework,
        test_patterns: test_patterns,
        load_paths: load_paths,
        environment: kind == "rails" ? RAILS_ENVIRONMENT.dup : {}
      }
    end

    private

    def kind
      return "rails" if @mode == "rails"
      return "ruby" if @mode == "ruby"

      rails_files? ? "rails" : "ruby"
    end

    def rails_files?
      File.file?(File.join(@root, "config", "application.rb")) &&
        File.file?(File.join(@root, "config", "environment.rb"))
    end

    def framework
      @resolved_framework
    end

    def resolve_framework!
      rspec = rspec_markers?
      minitest = minitest_markers?
      if @framework == "auto"
        raise_both_frameworks if rspec && minitest
        @resolved_framework = rspec ? "rspec" : "minitest"
      else
        @resolved_framework = @framework
      end
    end

    def rspec_markers?
      File.file?(File.join(@root, ".rspec")) || !Dir.glob(File.join(@root, "spec", "**", "*_spec.rb")).empty?
    end

    def raise_both_frameworks
      raise ArgumentError,
            "project contains both RSpec and Minitest markers; specify --framework rspec or --framework minitest"
    end

    def minitest_markers?
      !Dir.glob(File.join(@root, "test", "**", "*_test.rb")).empty? ||
        !Dir.glob(File.join(@root, "test", "**", "test_*.rb")).empty?
    end

    def test_patterns
      if framework == "rspec"
        %w[spec/**/*_spec.rb].freeze
      else
        %w[test/**/*_test.rb test/**/test_*.rb].freeze
      end
    end

    def load_paths
      [File.join(@root, "lib"), File.join(@root, framework == "rspec" ? "spec" : "test")]
    end

    def validate_root!
      raise ArgumentError, "project root does not exist: #{@root}" unless File.directory?(@root)
      return unless @mode == "rails" && !rails_files?

      raise ArgumentError, "Rails project requires config/application.rb and config/environment.rb"
    end
  end
end
