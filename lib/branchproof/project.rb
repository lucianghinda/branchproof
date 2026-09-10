# frozen_string_literal: true

module Branchproof
  # Resolves the project policy used by the isolated analysis worker.
  class Project
    MODES = %w[auto ruby rails].freeze
    RAILS_ENVIRONMENT = {
      "RAILS_ENV" => "test",
      "RACK_ENV" => "test",
      "PARALLEL_WORKERS" => "1",
      "DISABLE_BOOTSNAP" => "1",
      "DISABLE_SPRING" => "1"
    }.freeze

    def initialize(root:, mode: "auto")
      @root = File.expand_path(root)
      @mode = mode.to_s
      raise ArgumentError, "project must be auto, ruby, or rails" unless MODES.include?(@mode)

      validate_root!
    end

    def to_h
      {
        kind: kind,
        root: @root,
        load_paths: [File.join(@root, "lib"), File.join(@root, "test")],
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

    def validate_root!
      raise ArgumentError, "project root does not exist: #{@root}" unless File.directory?(@root)
      return unless @mode == "rails" && !rails_files?

      raise ArgumentError, "Rails project requires config/application.rb and config/environment.rb"
    end
  end
end
