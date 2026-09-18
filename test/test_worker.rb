# frozen_string_literal: true

require "test_helper"
require "branchproof/worker"

class TestWorker < Minitest::Test
  def test_missing_rspec_has_an_actionable_framework_diagnostic
    missing = LoadError.new("cannot load rspec/core")
    def missing.path = "rspec/core"
    Branchproof::Worker.stub(:require, ->(*) { raise missing }) do
      error = assert_raises(ArgumentError) do
        Branchproof::Worker.adapter_for({ framework: "rspec" }, Object.new)
      end
      assert_equal "rspec_missing", error.diagnostic_code
      assert_includes error.message, "application's test bundle"
    end
  end

  def test_dependency_load_error_is_not_misreported_as_missing_rspec
    missing = LoadError.new("cannot load application dependency")
    def missing.path = "application_dependency"
    Branchproof::Worker.stub(:require, ->(*) { raise missing }) do
      error = assert_raises(LoadError) do
        Branchproof::Worker.adapter_for({ framework: "rspec" }, Object.new)
      end
      assert_same missing, error
    end
  end

  def test_project_metadata_defaults_legacy_payloads_to_minitest
    metadata = Branchproof::Worker.project_metadata({ kind: "ruby", root: Dir.pwd, load_paths: [] }, nil)

    assert_equal "minitest", metadata[:framework]
  end

  def test_project_metadata_preserves_selected_framework
    metadata = Branchproof::Worker.project_metadata(
      { kind: "rails", framework: "rspec", root: Dir.pwd, load_paths: [] },
      { rails_version: "8.1.3.1", rspec_rails_version: "8.0.4" }
    )

    assert_equal "rspec", metadata[:framework]
    assert_equal "8.0.4", metadata[:rspec_rails_version]
  end

  def test_adapter_completion_errors_cannot_be_lost_when_loader_is_healthy
    diagnostic = { code: "rspec_run", severity: "error", message: "suite hook failed" }
    result = Branchproof::Worker.completion_result(
      baseline: { status: "ERROR", finalized: false, diagnostics: [diagnostic] },
      project: { kind: "ruby", framework: "rspec", root: Dir.pwd, load_paths: [] }, rails_metadata: nil,
      evidence: { completeness: { observation: true, analysis: true }, diagnostics: [] }, tests: [], diagnostics: []
    )

    assert_includes result[:diagnostics], diagnostic
    refute result.dig(:evidence, :completeness, :observation)
  end

  def test_configured_load_paths_are_prepended_in_project_order
    original = $LOAD_PATH.dup
    project = { root: Dir.pwd, load_paths: [File.join(Dir.pwd, "lib"), File.join(Dir.pwd, "test")] }

    Branchproof::Worker.send(:prepend_load_paths, project)

    assert_equal File.join(Dir.pwd, "lib"), $LOAD_PATH[0]
    assert_equal File.join(Dir.pwd, "test"), $LOAD_PATH[1]
  ensure
    $LOAD_PATH.replace(original) if original
  end

  def test_missing_load_paths_use_project_lib_and_test
    original = $LOAD_PATH.dup
    Branchproof::Worker.send(:prepend_load_paths, root: Dir.pwd, load_paths: [])

    assert_equal File.join(Dir.pwd, "lib"), $LOAD_PATH[0]
    assert_equal File.join(Dir.pwd, "test"), $LOAD_PATH[1]
  ensure
    $LOAD_PATH.replace(original) if original
  end

  def test_rails_metadata_records_kind_and_serial_policy
    metadata = Branchproof::Worker.send(:project_metadata, { kind: "rails", root: "/tmp/app", load_paths: [] },
                                        { rails_version: "8.1.0", serial_policy: { mode: "single_process", workers: 1 } })

    assert_equal "rails", metadata[:kind]
    assert_equal "8.1.0", metadata[:rails_version]
    assert_equal 1, metadata.dig(:serial_policy, :workers)
  end

  def test_worker_failures_preserve_project_metadata
    Dir.mktmpdir do |root|
      payload = { "project" => { "kind" => "rails", "root" => root, "load_paths" => [], "environment" => {} },
                  "result_path" => File.join(root, "result.json"), "marker_path" => File.join(root, "complete") }
      Branchproof::Worker.send(:write_failure, payload, "rails_boot", { message: "bad environment" })
      result = JSON.parse(File.binread(payload.fetch("result_path")))

      assert_equal "ERROR", result.fetch("status")
      assert_equal "rails", result.dig("project", "kind")
      assert_equal root, result.dig("project", "root")
      assert_equal 1, result.dig("project", "serial_policy", "workers")
    end
  end

  def test_loader_errors_make_completion_incomplete
    evidence = { completeness: { observation: true, attribution: true, analysis: true }, diagnostics: [] }
    result = Branchproof::Worker.send(:completion_result,
                                      baseline: { status: "PASSED", finalized: true },
                                      project: { kind: "ruby", root: Dir.pwd, load_paths: [] }, rails_metadata: nil,
                                      evidence: evidence, tests: [],
                                      diagnostics: [{ code: "loader_conflict", severity: "error", message: "hook changed" }])

    assert_equal "ERROR", result[:status]
    refute result[:finalized]
    assert_equal false, result.dig(:evidence, :completeness, :observation)
    assert_equal false, result.dig(:evidence, :completeness, :analysis)
    assert_equal "loader_conflict", result.dig(:evidence, :diagnostics, 0, :code)
  end
end
