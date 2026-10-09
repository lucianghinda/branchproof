# frozen_string_literal: true

require "rubygems"

module Branchproof
  # Checks static setup facts without loading a project's tests or source files.
  # rubocop:disable-next Metrics/ClassLength -- This service owns one small, cohesive static diagnostic document.
  class Doctor
    LIMITATIONS = [
      "Static checks only: application boot, framework test discovery, runner compatibility, source syntax and " \
      "instrumentation, and coverage are not verified.",
      "A discovered test file may contain no executable tests; runtime loader conflicts and application behavior " \
      "remain unverified."
    ].freeze
    NOT_CHECKED = ["application boot", "dependency loading", "test execution"].freeze
    FRAMEWORK_GEMS = {
      "minitest" => { name: "minitest", requirement: Gem::Requirement.new(">= 5.25.5", "< 7") },
      "rspec" => { name: "rspec-core", requirement: Gem::Requirement.new("~> 3.13.0") }
    }.freeze

    def initialize(options:, runtime: { engine: RUBY_ENGINE, version: RUBY_VERSION },
                   loaded_features: $LOADED_FEATURES,
                   gem_sources: { activated: Gem.loaded_specs,
                                  discoverable: ->(name) { Gem::Specification.find_all_by_name(name) } })
      @options = options
      @runtime_engine = runtime.fetch(:engine).to_s
      @runtime_version = runtime.fetch(:version).to_s
      @loaded_features = loaded_features
      @loaded_specs = gem_sources.fetch(:activated)
      @visible_specs = gem_sources.fetch(:discoverable)
    end

    def document(source_files:, test_files:)
      framework = framework_info(@options[:project][:framework])
      checks = build_checks(framework, source_files, test_files)
      result_document(framework: framework, checks: checks, source_files: source_files, test_files: test_files)
    end

    def self.error(message)
      ERROR_DOCUMENT.merge(runtime: { engine: RUBY_ENGINE, version: RUBY_VERSION },
                           checks: [{ code: "setup", status: "error", message: message.to_s }])
    end

    def self.terminal(document) = TerminalRenderer.new(document).render

    ERROR_DOCUMENT = {
      schema_version: 1, command: "doctor", status: "blocked", project: nil, configuration: nil,
      selection: nil, framework: nil, limitations: LIMITATIONS, not_checked: NOT_CHECKED
    }.freeze

    private

    def build_checks(framework, source_files, test_files)
      checks = [runtime_check, framework_check(framework), selection_check("sources", source_files),
                selection_check("tests", test_files)]
      loaded_runtime_warning(checks)
      checks
    end

    def result_document(framework:, checks:, source_files:, test_files:)
      status = checks.any? { |check| check[:status] == "error" } ? "blocked" : "ready"
      {
        schema_version: 1, command: "doctor", status: status,
        runtime: { engine: @runtime_engine, version: @runtime_version }, project: @options[:project],
        configuration: configuration_info(@options[:configuration], @options),
        selection: selection_info(source_files, test_files), framework: framework,
        checks: checks, limitations: LIMITATIONS, not_checked: NOT_CHECKED
      }
    end

    def runtime_check
      supported = @runtime_engine == "ruby" && Gem::Version.new(@runtime_version) >= Gem::Version.new("4.0")
      message = "CRuby >= 4.0 required; found #{@runtime_engine} #{@runtime_version}"
      check("runtime", supported ? "pass" : "error", message)
    rescue ArgumentError
      check("runtime", "error", "could not parse Ruby version #{@runtime_version.inspect}")
    end

    def framework_check(framework)
      requirement = FRAMEWORK_GEMS.fetch(framework[:name])[:requirement]
      version = framework[:version] && Gem::Version.new(framework[:version])
      supported = version && requirement.satisfied_by?(version)
      state = supported ? "pass" : "error"
      check("framework", state, framework_message(framework, requirement, version, supported))
    end

    def framework_message(framework, requirement, version, supported)
      if supported
        "#{framework[:gem]} #{version} is #{framework[:availability]}; version metadata is supported"
      elsif version
        "#{framework[:gem]} #{version} is #{framework[:availability]}, outside supported range #{requirement}; " \
          "add #{framework[:gem]} #{requirement} to the current test bundle"
      else
        "#{framework[:gem]} is not available; add #{framework[:gem]} #{requirement} to the current test bundle"
      end
    end

    def selection_check(kind, files)
      count = files.length
      if count.positive?
        check("#{kind}_selected", "pass", "#{count} #{kind.sub(/s\z/, "")} file(s) selected")
      else
        advice = selection_advice(kind)
        check("#{kind}_selected", "error", "no #{kind.sub(/s\z/, "")} files selected; #{advice}")
      end
    end

    def selection_advice(kind)
      return "check source globs and excludes" if kind == "sources"

      "check --test, configured tests, or project test patterns"
    end

    def loaded_runtime_warning(checks)
      conflicts = loaded_runtime_conflicts
      return if conflicts.empty?

      checks << check("loaded_runtime", "warning",
                      loaded_runtime_message(conflicts))
    end

    def loaded_runtime_message(conflicts)
      "#{conflicts.join(" and ")} already loaded; loader conflicts are not exercised by this static check"
    end

    def loaded_runtime_conflicts
      @loaded_features.filter_map do |feature|
        path = feature.to_s
        if path.match?(%r{(?:\A|/)spring(?:/|\.|\z)}i)
          "Spring"
        elsif path.match?(%r{(?:\A|/)bootsnap(?:/|\.|\z)}i)
          "Bootsnap"
        end
      end.uniq
    end

    def framework_info(framework)
      requirement = FRAMEWORK_GEMS.fetch(framework)
      spec = @loaded_specs[requirement[:name]]
      availability = "activated"
      unless spec
        spec = Array(@visible_specs.call(requirement[:name])).max_by(&:version)
        availability = "discoverable" if spec
      end
      { name: framework, gem: requirement[:name], version: spec&.version&.to_s,
        availability: spec ? availability : "missing", requirement: requirement[:requirement].to_s }
    end

    def configuration_info(config, options)
      { state: configuration_state(config, options), path: configuration_path(config, options),
        minimum: config ? config.fetch(:minimum, {}) : {},
        minimum_changed: config ? config.fetch(:minimum_changed, {}) : {} }
    end

    def configuration_state(config, options)
      return "disabled" if options[:config_disabled]
      return "loaded" if config

      "default absent"
    end

    def configuration_path(config, options)
      return nil if options[:config_disabled]

      config ? config[:path] : File.expand_path(".branchproof.json", options[:project][:root])
    end

    def selection_info(source_files, test_files)
      {
        source_patterns: @options[:source_patterns],
        test_patterns: @options[:test_patterns],
        excludes: @options[:exclude],
        source_count: source_files.length,
        test_count: test_files.length
      }
    end

    def check(code, status, message)
      { code: code, status: status, message: message }
    end
  end

  # Checks static setup facts and renders diagnostics without executing project code.
  class Doctor
    # Formats the structured document as concise terminal output.
    class TerminalRenderer
      def initialize(document)
        @document = document
      end

      def render
        lines = header_lines
        lines.concat(project_lines, configuration_lines, selection_lines, check_lines, limitation_lines)
        lines << not_checked_line
        "#{lines.join("\n")}\n"
      end

      private

      def header_lines
        ["Branchproof doctor: #{@document[:status]}",
         "Ruby: #{@document.dig(:runtime, :engine)} #{@document.dig(:runtime, :version)}"]
      end

      def project_lines
        project = @document[:project]
        return [] unless project

        framework = @document[:framework]
        ["Project: #{project[:kind]} (#{project[:root]})",
         "Framework: #{framework[:name]} #{framework[:version] || "unavailable"} (#{framework[:availability]})"]
      end

      def configuration_lines
        configuration = @document[:configuration]
        return [] unless configuration

        path = configuration[:path] ? " (#{configuration[:path]})" : nil
        minimum = configuration[:minimum].empty? ? "none" : configuration[:minimum].inspect
        changed = configuration[:minimum_changed].empty? ? "none" : configuration[:minimum_changed].inspect
        ["Config: #{configuration[:state]}#{path}", "Configured minima: #{minimum} (not evaluated)",
         "Configured changed minima: #{changed} (not evaluated)"]
      end

      def selection_lines
        selection = @document[:selection]
        return [] unless selection

        ["Sources: #{selection[:source_count]} files from #{selection[:source_patterns].join(", ")}",
         "Tests: #{selection[:test_count]} files from #{selection[:test_patterns].join(", ")}",
         "Excludes: #{selection[:excludes].empty? ? "none" : selection[:excludes].join(", ")}"]
      end

      def check_lines
        @document[:checks].map { |check| "#{check[:status].upcase}: #{check[:message]}" }
      end

      def limitation_lines
        @document[:limitations].map { |limitation| "Static-only: #{limitation}" }
      end

      def not_checked_line
        "Not checked: #{@document.fetch(:not_checked).join(", ")}. Run analyze to verify those."
      end
    end
  end
end
