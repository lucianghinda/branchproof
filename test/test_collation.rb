# frozen_string_literal: true

require "test_helper"
require "branchproof/collation"
require "tmpdir"
require "stringio"

class TestCollation < Minitest::Test
  def test_recomputes_cross_shard_mcdc_and_preserves_input_documents
    left = raw_report(run_id: "run-left", root_name: "left", tests: [
                        ["test-left", [[true, true], true], [[true, false], false]]
                      ])
    right = raw_report(run_id: "run-right", root_name: "right", tests: [
                         ["test-right", [[false, nil], false]]
                       ])
    before = Marshal.load(Marshal.dump([left, right]))

    result = Branchproof::Collation.new(
      inputs: [{ id: "left", path: "left.json", document: left },
               { id: "right", path: "right.json", document: right }],
      expected_shards: %w[left right]
    ).call

    assert_equal "1.7", result.fetch("schema_version")
    assert_equal "complete", result.dig("collation", "collection_status")
    assert_equal %w[run-left run-right], result.fetch("run_ids").sort
    assert_equal 2, result.dig("baseline", "executed_tests")
    assert_equal true, result.dig("completeness", "observation")
    decisions = result.dig("analysis", "decisions")
    condition = decisions.first.fetch("condition_results").first
    assert_equal "PROVEN", condition.fetch("status")
    assert_equal before, [left, right]
    assert_equal(%w[test-left test-right], result.dig("observations", "tests").map { |test| test.fetch("id") })
    assert_equal "right.rb", result.dig("run_metadata", "test_locations", "test-right", "relative_path")
  end

  def test_missing_expected_shard_marks_collection_incomplete
    report = raw_report(run_id: "run-left", root_name: "left", tests: [["test-left", [[true, true], true]]])

    result = Branchproof::Collation.new(
      inputs: [{ id: "left", path: "left.json", document: report }],
      expected_shards: %w[left right]
    ).call

    assert_equal "incomplete", result.dig("collation", "collection_status")
    assert_equal ["right"], result.dig("collation", "missing_shards")
    assert_equal "INCOMPLETE", result.dig("baseline", "status")
    assert_equal false, result.dig("baseline", "finalized")
    assert_equal false, result.dig("completeness", "observation")
    assert_equal false, result.dig("analysis", "completeness", "observation")
  end

  def test_false_input_completeness_and_analyzer_search_limits_are_preserved
    incomplete = raw_report(run_id: "run-incomplete", root_name: "incomplete",
                            tests: [["test-incomplete", [[true, true], true]]])
    %w[completeness].each do |section|
      incomplete[section].transform_values! { false }
    end
    incomplete.dig("observations", "completeness").transform_values! { false }
    incomplete.dig("analysis", "completeness").transform_values! { false }

    result = Branchproof::Collation.new(inputs: [{ id: "incomplete", path: "incomplete.json", document: incomplete }],
                                        expected_shards: ["incomplete"]).call
    assert_equal "INCOMPLETE", result.dig("baseline", "status")
    %w[observation attribution analysis].each do |field|
      assert_equal false, result.dig("completeness", field)
      assert_equal false, result.dig("observations", "completeness", field)
      assert_equal false, result.dig("analysis", "completeness", field)
    end

    limited = raw_report(run_id: "run-limited", root_name: "limited", tests: [["test-limited", [[true, true], true]]],
                         limits_overrides: { constraint_search_states: 1 })
    assert_equal false, limited.dig("analysis", "completeness", "analysis")
    output = Branchproof::Collation.new(inputs: [{ id: "limited", path: "limited.json", document: limited }],
                                        expected_shards: ["limited"]).call
    assert_equal false, output.dig("analysis", "completeness", "analysis")
    assert_equal "INCOMPLETE", output.dig("baseline", "status")
  end

  def test_failed_and_error_inputs_keep_failure_precedence_and_skip_reanalysis
    failed = raw_report(run_id: "run-failed", root_name: "failed", tests: [["test-failed", [[true, true], true]]])
    failed["baseline"].merge!("status" => "FAILED", "failed_tests" => 1)
    failed.dig("baseline", "tests", 0)["status"] = "failed"
    failed.dig("observations", "tests", 0)["status"] = "failed"
    failed_result = Branchproof::Collation.new(
      inputs: [{ id: "failed", path: "failed.json", document: failed }], expected_shards: ["failed"]
    ).call
    assert_equal "FAILED", failed_result.dig("baseline", "status")
    assert_nil failed_result["analysis"]

    error = raw_report(run_id: "run-error", root_name: "error", tests: [["test-error", [[true, true], true]]])
    error["baseline"].merge!("status" => "ERROR", "finalized" => false)
    error_result = Branchproof::Collation.new(
      inputs: [{ id: "error", path: "error.json", document: error }], expected_shards: %w[error missing]
    ).call
    assert_equal "ERROR", error_result.dig("baseline", "status")
    assert_equal false, error_result.dig("baseline", "finalized")
    assert_nil error_result["analysis"]
  end

  def test_rejects_baseline_and_observation_status_or_count_contradictions
    cases = {
      failed_observation: lambda do |report|
        report.dig("observations", "tests", 0)["status"] = "failed"
      end,
      failure_count: lambda do |report|
        report["baseline"]["failed_tests"] = 0
        report.dig("baseline", "tests", 0)["status"] = "failed"
        report.dig("observations", "tests", 0)["status"] = "failed"
      end,
      contradictory_status: lambda do |report|
        report.dig("baseline", "tests", 0)["status"] = "failed"
      end,
      unknown_status: lambda do |report|
        report.dig("observations", "tests", 0)["status"] = "unknown"
      end
    }

    cases.each do |name, corrupt|
      report = raw_report(run_id: "run-#{name}", root_name: name.to_s,
                          tests: [["test-#{name}", [[true, true], true]]])
      corrupt.call(report)

      error = assert_raises(ArgumentError, name.to_s) do
        Branchproof::Collation.new(inputs: [{ id: name.to_s, path: "#{name}.json", document: report }],
                                   expected_shards: [name.to_s]).call
      end
      assert_match(/status|failure|skip|PASSED/i, error.message)
    end
  end

  def test_unknown_collection_is_unfinalized_but_keeps_informational_analysis
    report = raw_report(run_id: "run-left", root_name: "left", tests: [["test-left", [[true, true], true]]])

    result = Branchproof::Collation.new(inputs: [{ id: "left", path: "left.json", document: report }]).call

    assert_equal "unknown", result.dig("collation", "collection_status")
    assert_nil result.dig("collation", "expected_shards")
    assert_equal "INCOMPLETE", result.dig("baseline", "status")
    assert_equal false, result.dig("completeness", "observation")
    refute_nil result["analysis"]
  end

  def test_conflicting_overlap_in_run_ids_is_rejected
    first = raw_report(run_id: "same-run", root_name: "left", tests: [["test-left", [[true, true], true]]])
    second = raw_report(run_id: "same-run", root_name: "right", tests: [["test-right", [[false, true], false]]])

    error = assert_raises(ArgumentError) do
      Branchproof::Collation.new(inputs: [{ id: "left", path: "left.json", document: first },
                                          { id: "right", path: "right.json", document: second }]).call
    end

    assert_match(/run.?id overlap/i, error.message)
  end

  def test_exact_duplicate_artifacts_are_idempotent_and_same_artifact_cannot_claim_two_ids
    report = raw_report(run_id: "run-left", root_name: "left", tests: [["test-left", [[true, true], true]]])
    duplicate = Branchproof::Collation.new(inputs: [{ id: "left", path: "left.json", document: report },
                                                    { id: "left", path: "copy.json", document: report }],
                                           expected_shards: ["left"]).call
    assert_equal 1, duplicate.dig("baseline", "executed_tests")
    assert_equal %w[copy.json left.json], duplicate.dig("collation", "shards", 0, "paths")

    error = assert_raises(ArgumentError) do
      Branchproof::Collation.new(inputs: [{ id: "left", path: "left.json", document: report },
                                          { id: "right", path: "copy.json", document: report }],
                                 expected_shards: %w[left right]).call
    end
    assert_match(/two shard IDs/, error.message)
  end

  def test_output_is_independent_of_input_order_and_does_not_claim_one_shards_selection
    left = raw_report(run_id: "run-left", root_name: "left", tests: [["test-left", [[true, true], true]]])
    right = raw_report(run_id: "run-right", root_name: "right", tests: [["test-right", [[false, nil], false]]])
    inputs = [{ id: "left", path: "left.json", document: left },
              { id: "right", path: "right.json", document: right }]

    first = Branchproof::Collation.new(inputs: inputs, expected_shards: %w[left right]).call
    reversed = Branchproof::Collation.new(inputs: inputs.reverse, expected_shards: %w[left right]).call

    assert_equal first, reversed
    assert_equal [], first.dig("run_metadata", "runner_args")
    assert_nil first.dig("run_metadata", "seed")
    assert_equal %w[test/left_test.rb test/right_test.rb], first.dig("run_metadata", "test_files").sort
    refute first.fetch("baseline").key?("evidence")
  end

  def test_incompatible_reconstruction_settings_are_rejected
    first = raw_report(run_id: "run-left", root_name: "left", tests: [["test-left", [[true, true], true]]])
    second = raw_report(run_id: "run-right", root_name: "right", tests: [["test-right", [[false, nil], false]]],
                        limits_overrides: { tests_per_run: 25_000 })

    assert_raises(ArgumentError) do
      Branchproof::Collation.new(inputs: [{ id: "left", path: "left.json", document: first },
                                          { id: "right", path: "right.json", document: second }]).call
    end
  end

  def test_union_storage_caps_are_rejected_with_an_actionable_error
    left = raw_report(run_id: "run-left", root_name: "left", tests: [["test-left", [[true, true], true]]],
                      limits_overrides: { tests_per_run: 1 })
    right = raw_report(run_id: "run-right", root_name: "right", tests: [["test-right", [[false, nil], false]]],
                       limits_overrides: { tests_per_run: 1 })

    error = assert_raises(ArgumentError) do
      Branchproof::Collation.new(inputs: [{ id: "left", path: "left.json", document: left },
                                          { id: "right", path: "right.json", document: right }]).call
    end

    assert_match(/union.*tests_per_run.*limit/i, error.message)
  end

  def test_conflicting_repeated_test_locations_or_source_digests_are_rejected
    first = raw_report(run_id: "run-left", root_name: "left", tests: [["shared-test", [[true, true], true]]])
    second = raw_report(run_id: "run-right", root_name: "right", tests: [["shared-test", [[true, false], false]]])
    second.dig("run_metadata", "test_locations", "shared-test")["relative_path"] = "elsewhere.rb"
    error = assert_raises(ArgumentError) do
      Branchproof::Collation.new(inputs: [{ id: "left", path: "left.json", document: first },
                                          { id: "right", path: "right.json", document: second }]).call
    end
    assert_match(/test location/, error.message)

    second.dig("run_metadata", "test_locations", "shared-test")["relative_path"] = "left.rb"
    second.dig("observations", "tests", 0)["source_digest"] = "other-source"
    second.dig("baseline", "tests", 0)["source_digest"] = "other-source"
    error = assert_raises(ArgumentError) do
      Branchproof::Collation.new(inputs: [{ id: "left", path: "left.json", document: first },
                                          { id: "right", path: "right.json", document: second }]).call
    end
    assert_match(/test identity/, error.message)
  end

  def test_schema_17_roundtrips_non_boolean_decisions
    report = raw_report(run_id: "run-case", root_name: "case", source: "case value\nwhen 1 then :one\nwhen 2 then :two\nend\n",
                        tests: [["test-case"]])

    result = Branchproof::Collation.new(inputs: [{ id: "case", path: "case.json", document: report }],
                                        expected_shards: ["case"]).call

    assert_equal "1.7", result.fetch("schema_version")
    refute_equal "boolean", result.dig("source_inventory", "decisions", 0, "kind")
    assert_equal result, Branchproof::SavedReport.new(result).validate!
  end

  def test_changed_policy_recalculation_and_saved_override_preserve_schema_one_seven
    report = raw_report(run_id: "run-changed", root_name: "changed", tests: [["test-changed", [[true, true], true]]],
                        changed_policy: { mcdc: 50 })

    result = Branchproof::Collation.new(inputs: [{ id: "changed", path: "changed.json", document: report }],
                                        expected_shards: ["changed"]).call
    assert_equal "1.7", result.fetch("schema_version")
    refute_empty result.fetch("changed_coverage_policy").fetch("minimum_changed")
    assert_equal result, Branchproof::SavedReport.new(result).validate!

    output = StringIO.new
    Branchproof::Report.from_document(document: result, minimum_changed: { mcdc: 90 })
                       .write(io: output, format: :json)
    overridden = JSON.parse(output.string)
    assert_equal "1.7", overridden.fetch("schema_version")
    assert_equal({ "mcdc" => 90 }, overridden.dig("changed_coverage_policy", "minimum_changed"))
    assert_equal overridden, Branchproof::SavedReport.new(overridden).validate!
  end

  def test_saved_collation_rejects_undeclared_shard_ids
    report = raw_report(run_id: "run-left", root_name: "left", tests: [["test-left", [[true, true], true]]])
    result = Branchproof::Collation.new(inputs: [{ id: "left", path: "left.json", document: report }],
                                        expected_shards: ["left"]).call
    forged = Marshal.load(Marshal.dump(result))
    extra = Marshal.load(Marshal.dump(forged.dig("collation", "shards", 0)))
    extra["id"] = "undeclared"
    extra["report_digest"] = "0" * 64
    extra["run_ids"] = ["run-extra"]
    extra["baseline"].merge!("status" => "PASSED", "executed_tests" => 0,
                             "failed_tests" => 0, "skipped_tests" => 0, "finalized" => true)
    forged.dig("collation", "shards") << extra
    forged["run_ids"] << "run-extra"

    assert_raises(ArgumentError) { Branchproof::SavedReport.new(forged).validate! }

    forged = Marshal.load(Marshal.dump(result))
    forged.dig("collation", "shards", 0, "baseline")["failed_tests"] = 1
    assert_raises(ArgumentError) { Branchproof::SavedReport.new(forged).validate! }
  end

  def test_saved_collation_rejects_forged_test_statuses_and_empty_expected_ids
    report = raw_report(run_id: "run-valid", root_name: "valid", tests: [["test-valid", [[true, true], true]]])
    result = Branchproof::Collation.new(inputs: [{ id: "valid", path: "valid.json", document: report }],
                                        expected_shards: ["valid"]).call
    forged = Marshal.load(Marshal.dump(result))
    forged.dig("observations", "tests", 0)["status"] = "failed"
    assert_raises(ArgumentError) { Branchproof::SavedReport.new(forged).validate! }

    forged = Marshal.load(Marshal.dump(result))
    forged.dig("observations", "tests", 0)["status"] = "running"
    forged.dig("baseline", "tests", 0)["status"] = "running"
    assert_raises(ArgumentError) { Branchproof::SavedReport.new(forged).validate! }

    forged = Marshal.load(Marshal.dump(result))
    forged.dig("collation", "expected_shards")[0] = ""
    assert_raises(ArgumentError) { Branchproof::SavedReport.new(forged).validate! }
  end

  def test_repeated_test_id_uses_worst_status_and_sums_phase_counts
    failed = raw_report(run_id: "run-failed", root_name: "failed", tests: [["shared-test", [[true, true], true]]])
    passed = raw_report(run_id: "run-passed", root_name: "passed", tests: [["shared-test", [[true, false], false]]])
    failed.dig("observations", "tests", 0)["status"] = "failed"
    failed.dig("baseline", "tests", 0)["status"] = "failed"
    failed["baseline"].merge!("status" => "FAILED", "failed_tests" => 1)
    passed.dig("run_metadata", "test_locations", "shared-test")["relative_path"] = "failed.rb"

    result = Branchproof::Collation.new(inputs: [{ id: "failed", path: "failed.json", document: failed },
                                                 { id: "passed", path: "passed.json", document: passed }],
                                        expected_shards: %w[failed passed]).call

    assert_equal "FAILED", result.dig("baseline", "status")
    assert_equal "failed", result.dig("observations", "tests", 0, "status")
    assert_equal "failed", result.dig("baseline", "tests", 0, "status")
    assert_equal 2, result.dig("observations", "tests", 0, "phase_counts", "body")
    assert_nil result["analysis"]
  end

  private

  def raw_report(run_id:, root_name:, tests:, source: "if left && right\nend\n", limits_overrides: {},
                 changed_policy: nil)
    Dir.mktmpdir("branchproof-collation-#{root_name}") do |root|
      relative_path = "decision.rb"
      path = File.join(root, relative_path)
      File.write(path, source)
      limits = Branchproof::Limits.normalize(limits_overrides)
      inventory = Branchproof::Source.new(root: root, limits: limits).inventory(paths: [path])
      decision = inventory.fetch(:decisions).first
      evidence = Branchproof::Evidence.new(inventory: inventory, limits: limits, run_id: run_id)
      tests.each do |test_id, *executions|
        evidence.register_test(test: { id: test_id, adapter: "minitest", name: "DecisionTest##{test_id}",
                                       class_name: "DecisionTest", method_name: test_id, status: "passed",
                                       phase_counts: {} })
        executions.each do |observations, outcome|
          evidence.record(execution: { run_id: run_id, decision_id: decision.fetch(:id), test_id: test_id,
                                       phase: "body", observations: observations.each_with_index.filter_map do |value, index|
                                         [index, value] if [true, false].include?(value)
                                       end,
                                       outcome: outcome, status: "completed" })
        end
      end
      snapshot = evidence.snapshot
      analysis = Branchproof::Analyzer.new(inventory: inventory, evidence: snapshot, limits: limits).call
      baseline = { status: "PASSED", finalized: true, executed_tests: tests.length,
                   failed_tests: 0, skipped_tests: 0, tests: snapshot.fetch(:tests),
                   project: { kind: "ruby", framework: "minitest", framework_version: "5.27.0", root: root } }
      test_locations = tests.to_h do |test_id, _|
        [test_id, { relative_path: "#{root_name}.rb", line: 1 }]
      end
      metadata = { requested_level: 3, project_kind: "ruby", project_root: root, framework: "minitest",
                   framework_version: "5.27.0", limits: limits, reachability: true,
                   test_locations: test_locations, test_files: ["test/#{root_name}_test.rb"], runner_args: [] }
      changed_scope = if changed_policy
                        { version: "1.0", requested_ref: "main", base_commit: "a" * 40,
                          comparison: "tracked_worktree", untracked: "excluded", status: "complete",
                          files: [{ path: relative_path, status: "M", hunks: [] }],
                          decision_ids: inventory.fetch(:decisions).map { |item| item.fetch(:id) } }
                      end
      output = StringIO.new
      Branchproof::Report.new(inventory: inventory, evidence: snapshot, analysis: analysis, minima: [],
                              baseline: baseline, diagnostics: [], level: 3, run_metadata: metadata,
                              changed_scope: changed_scope, minimum_changed: changed_policy)
                         .write(io: output, format: :json)
      JSON.parse(output.string)
    end
  end
end
