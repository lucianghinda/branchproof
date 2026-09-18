# frozen_string_literal: true

# rubocop:disable Layout/LineLength, Metrics/ModuleLength

require "json"
require "tmpdir"
require "stringio"
require "fileutils"

module Branchproof
  # Runs one isolated test worker and atomically exports its result.
  module Worker
    module_function

    def child_process(config_path)
      payload = JSON.parse(File.binread(config_path))
      project = symbolize(payload.fetch("project"))
      prepend_load_paths(project)
      inventory = symbolize(payload.fetch("inventory"))
      limits = symbolize(payload.fetch("limits"))
      evidence = Branchproof::Evidence.new(inventory: inventory, limits: limits, run_id: payload.fetch("run_id"))
      runtime = Branchproof::Runtime
      runtime.boot(evidence: evidence)
      loader = Branchproof::Loader.new(inventory: inventory, instrumenter: Branchproof::Instrumenter.new)
      status = loader.install
      return write_failure(payload, "loader", status) unless status[:status].to_sym == :installed

      adapter = adapter_for(project, runtime)
      guard_late_rspec_execution(adapter, payload) if project[:framework].to_s == "rspec"
      rails_metadata = nil
      ARGV.replace(payload.fetch("runner_args"))
      callbacks = if project[:framework].to_s == "rspec"
                    { test_selection_explicit: payload.fetch("test_selection_explicit", false), after_load: lambda {
                      require_relative "rails_support"
                      rails_metadata = Branchproof::RailsSupport.validate_rspec!(project: project)
                    } }
                  else
                    {}
                  end
      before_load = lambda do
        rails_metadata = boot_project(project) unless project[:framework].to_s == "rspec"
      end
      on_complete = lambda do |baseline|
        result = completion_result(baseline: baseline, project: project, rails_metadata: rails_metadata,
                                   evidence: runtime.snapshot, tests: adapter.tests.values,
                                   diagnostics: loader.diagnostics)
        write_completion(payload, result)
      end
      exit_status = adapter.run(test_files: payload.fetch("test_files"), runner_args: payload.fetch("runner_args"),
                                before_load: before_load, on_complete: on_complete, **callbacks)
      return exit_status if project[:framework].to_s == "rspec"

      adapter.validate_runner!
      Minitest.autorun
      nil
    rescue StandardError => e
      code = if e.respond_to?(:diagnostic_code)
               e.diagnostic_code
             elsif e.message.match?(/parallel|runner|bisect|DRb|dry.run/)
               "unsupported_runner"
             elsif defined?(Branchproof::RailsSupport::Error) && e.is_a?(Branchproof::RailsSupport::Error)
               "rails_boot"
             else
               "worker"
             end
      write_failure(payload || {}, code, { message: e.message }) if payload
      2
    end

    def adapter_for(project, runtime)
      if project[:framework].to_s == "rspec"
        begin
          require "rspec/core"
        rescue LoadError => e
          raise unless e.path == "rspec/core"

          error = ArgumentError.new("RSpec is not available; add rspec to the application's test bundle")
          def error.diagnostic_code = "rspec_missing"
          raise error
        end
        require_relative "rspec_adapter"
        Branchproof::RSpecAdapter.new(runtime: runtime)
      else
        require "minitest"
        require "minitest/test"
        require_relative "minitest_adapter"
        Branchproof::MinitestAdapter.new(runtime: runtime)
      end
    end

    # Installed before application hooks, so this runs after their at_exit work.
    # A rescued second runner must still invalidate the already-exported result.
    def guard_late_rspec_execution(adapter, payload)
      at_exit do
        error = adapter.late_execution_error
        if error
          result = symbolize(JSON.parse(File.binread(payload.fetch("result_path"))))
          diagnostic = { code: "unsupported_runner", severity: "error", message: error.message }
          result.merge!(status: "ERROR", finalized: false, exit_status: 2,
                        diagnostics: Array(result[:diagnostics]) + [diagnostic])
          result[:evidence] = incomplete_evidence(result[:evidence], [diagnostic]) if result[:evidence]
          write_completion(payload, result)
          exit(2)
        end
      end
    end

    def legacy_project
      { "kind" => "ruby", "root" => Dir.pwd,
        "load_paths" => [File.join(Dir.pwd, "lib"), File.join(Dir.pwd, "test")],
        "environment" => {} }
    end

    def prepend_load_paths(project)
      paths = Array(project[:load_paths])
      paths = legacy_project.fetch("load_paths") if paths.empty?
      paths.reverse_each { |path| $LOAD_PATH.unshift(File.expand_path(path.to_s, project[:root].to_s)) }
      nil
    end

    def boot_project(project)
      return nil unless project[:kind].to_s == "rails"

      require_relative "rails_support"
      Branchproof::RailsSupport.boot(project: project)
    end

    def project_metadata(project, rails_metadata)
      framework = project[:framework].to_s.empty? ? "minitest" : project[:framework].to_s
      version = if framework == "rspec" && defined?(RSpec::Core::Version::STRING)
                  RSpec::Core::Version::STRING
                elsif framework == "minitest" && defined?(Minitest::VERSION)
                  Minitest::VERSION
                end
      metadata = { kind: project[:kind].to_s, root: project[:root].to_s,
                   framework: framework, framework_version: version,
                   load_paths: Array(project[:load_paths]).map(&:to_s), serial_policy: { mode: "single_process", workers: 1 } }
      metadata.merge!(rails_metadata) if rails_metadata
      metadata
    end

    # This result boundary intentionally carries the complete worker payload.
    # rubocop:disable-next Metrics/ParameterLists
    def completion_result(baseline:, project:, rails_metadata:, evidence:, tests:, diagnostics:)
      diagnostics = Array(baseline[:diagnostics]) + diagnostics
      result = baseline.merge(project: project_metadata(project, rails_metadata), evidence: evidence,
                              tests: tests, diagnostics: diagnostics)
      return result unless diagnostics.any? { |diagnostic| diagnostic[:severity].to_s == "error" }

      result.merge(status: "ERROR", finalized: false, exit_status: 2,
                   evidence: incomplete_evidence(evidence, diagnostics))
    end

    def incomplete_evidence(evidence, diagnostics)
      copy = Marshal.load(Marshal.dump(evidence))
      copy[:diagnostics] = Array(copy[:diagnostics]) + diagnostics
      copy[:completeness] = (copy[:completeness] || {}).merge(observation: false, analysis: false)
      copy
    end

    def write_completion(payload, result)
      path = payload.fetch("result_path")
      temporary = "#{path}.tmp-#{Process.pid}"
      File.binwrite(temporary, JSON.generate(normalize(result)))
      File.rename(temporary, path)
      File.binwrite(payload.fetch("marker_path"), "complete\n")
      nil
    end

    def write_failure(payload, code, details)
      return unless payload["result_path"]

      write_completion(payload, { status: "ERROR", executed_tests: 0, failed_tests: 0, skipped_tests: 0,
                                  finalized: false, exit_status: 2, project: project_metadata_for(payload),
                                  diagnostics: [{ code: code, severity: "error", message: details.to_s }] })
    end

    def project_metadata_for(payload)
      project = symbolize(payload.fetch("project", legacy_project))
      project_metadata(project, nil)
    end

    def symbolize(value)
      return value.map { symbolize(_1) } if value.is_a?(Array)
      return value.transform_keys(&:to_sym).transform_values { symbolize(_1) } if value.is_a?(Hash)

      value
    end

    def normalize(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), result| result[key.to_s] = normalize(item) }
      when Array then value.map { normalize(_1) }
      when Symbol then value.to_s
      else value
      end
    end
  end
end
# rubocop:enable Layout/LineLength, Metrics/ModuleLength
