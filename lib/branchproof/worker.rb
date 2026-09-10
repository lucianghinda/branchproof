# frozen_string_literal: true

# rubocop:disable Layout/LineLength, Metrics/ModuleLength

require "json"
require "tmpdir"
require "stringio"
require "fileutils"

module Branchproof
  # Runs one isolated Minitest worker and atomically exports its result.
  module Worker
    module_function

    def child_process(config_path)
      payload = JSON.parse(File.binread(config_path))
      project = symbolize(payload.fetch("project", legacy_project))
      prepend_load_paths(project)
      inventory = symbolize(payload.fetch("inventory"))
      limits = symbolize(payload.fetch("limits"))
      require "minitest"
      require "minitest/test"
      require_relative "minitest_adapter"
      evidence = Branchproof::Evidence.new(inventory: inventory, limits: limits, run_id: payload.fetch("run_id"))
      runtime = Branchproof::Runtime
      runtime.boot(evidence: evidence)
      loader = Branchproof::Loader.new(inventory: inventory, instrumenter: Branchproof::Instrumenter.new)
      status = loader.install
      return write_failure(payload, "loader", status) unless status[:status].to_sym == :installed

      adapter = Branchproof::MinitestAdapter.new(runtime: runtime)
      rails_metadata = nil
      ARGV.replace(payload.fetch("runner_args"))
      adapter.run(test_files: payload.fetch("test_files"), runner_args: payload.fetch("runner_args"),
                  before_load: lambda {
                    rails_metadata = boot_project(project)
                  }, on_complete: lambda { |baseline|
                    result = completion_result(baseline: baseline, project: project, rails_metadata: rails_metadata,
                                               evidence: runtime.snapshot, tests: adapter.tests.values,
                                               diagnostics: loader.diagnostics)
                    write_completion(payload, result)
                  })
      adapter.validate_runner!
      Minitest.autorun
      nil
    rescue StandardError => e
      code = if e.message.include?("parallel")
               "unsupported_runner"
             elsif defined?(Branchproof::RailsSupport::Error) && e.is_a?(Branchproof::RailsSupport::Error)
               "rails_boot"
             else
               "worker"
             end
      write_failure(payload || {}, code, { message: e.message }) if payload
      2
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
      metadata = { kind: project[:kind].to_s, root: project[:root].to_s,
                   load_paths: Array(project[:load_paths]).map(&:to_s), serial_policy: { mode: "single_process", workers: 1 } }
      metadata.merge!(rails_metadata) if rails_metadata
      metadata
    end

    # This result boundary intentionally carries the complete worker payload.
    # rubocop:disable-next Metrics/ParameterLists
    def completion_result(baseline:, project:, rails_metadata:, evidence:, tests:, diagnostics:)
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
