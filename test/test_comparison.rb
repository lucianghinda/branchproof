# frozen_string_literal: true

require "test_helper"
require "branchproof/comparison"

class TestComparison < Minitest::Test
  def document(status:, digest: "digest", run_metadata: {}, completeness: nil, vectors: nil, tests: nil,
               source_inventory: nil, analysis_status: nil, baseline_status: "PASSED")
    vectors ||= [
      { id: "v1", decision_id: "d1", values: [true, true], outcome: true, test_ids: ["t1"] },
      { id: "v2", decision_id: "d1", values: [false, true], outcome: false, test_ids: ["t2"] }
    ]
    tests ||= [
      { id: "t1", adapter: "minitest", class_name: "DecisionTest", method_name: "test_true",
        source: { relative_path: "test/decision_test.rb", line: 8 } },
      { id: "t2", adapter: "minitest", class_name: "DecisionTest", method_name: "test_false",
        source: { relative_path: "test/decision_test.rb", line: 12 } }
    ]
    source_inventory ||= { source_units: [{ source_id: "s1", relative_path: "lib/decision.rb", digest: digest }],
                           decisions: [{ id: "d1", source_id: "s1", expression: "left && right", line: 4,
                                         conditions: [{ id: "c1", index: 0, expression: "left", byte_start: 0,
                                                        byte_length: 4 },
                                                      { id: "c2", index: 1, expression: "right", byte_start: 9,
                                                        byte_length: 5 }] }] }
    analysis_status ||= status
    completeness ||= { observation: true, attribution: true, analysis: true }
    {
      schema_version: "1.1", criterion_version: "masking_occurrence_v1",
      source_inventory: source_inventory,
      observations: { run_ids: ["run"], vectors: vectors, tests: tests,
                      completeness: { observation: true, attribution: true, analysis: true } },
      analysis: { decisions: [{ decision_id: "d1", condition_results: [
        { condition_id: "c1", status: analysis_status, canonical_pair: %w[v1 v2] },
        { condition_id: "c2", status: "NOT_PROVEN" }
      ] }], completeness: { observation: true, attribution: true, analysis: true } },
      baseline: { status: baseline_status, finalized: true },
      completeness: completeness,
      runtime: "ruby-3.4",
      run_metadata: { project_kind: "ruby", source_patterns: ["lib/**/*.rb"], test_patterns: ["test/**/*_test.rb"],
                      test_files: ["test/decision_test.rb"], runner_args: [], limits: {}, **run_metadata }
    }
  end

  def test_lost_proof_is_reported_with_previous_witness
    before = document(status: "PROVEN")
    after = document(status: "NOT_PROVEN")
    result = Branchproof::Comparison.new(before: before, after: after).call

    lost = result.fetch("changes").find { |change| change["condition_id"] == "c1" }
    assert_equal "lost proof", lost.fetch("change")
    assert_equal "lib/decision.rb", lost.fetch("relative_path")
    assert_equal "DecisionTest#test_true (test/decision_test.rb:8)", lost.dig("previous_witness", 0, "tests", 0)
    assert_equal 1, result.fetch("regressions")
    assert_equal "complete", result.fetch("status")
  end

  def test_changed_source_is_incomplete_and_has_no_condition_delta
    result = Branchproof::Comparison.new(before: document(status: "PROVEN"), after: document(status: "NOT_PROVEN", digest: "changed")).call

    assert_equal "comparison incomplete", result.fetch("status")
    assert_empty result.fetch("changes")
    assert_equal "lib/decision.rb", result.dig("changed_sources", 0, "relative_path")
  end

  def test_seed_changes_do_not_make_runs_incomparable
    before = document(status: "NOT_PROVEN", run_metadata: { runner_args: ["--seed", "1", "--verbose"] })
    after = document(status: "NOT_PROVEN", run_metadata: { runner_args: ["--seed", "2", "--verbose"] })

    refute_includes Branchproof::Comparison.new(before: before, after: after).call.fetch("reasons"), "runner_args differs"
  end

  def test_missing_metadata_and_nested_incompleteness_are_incomplete
    missing = document(status: "PROVEN").dup
    missing.delete(:run_metadata)
    result = Branchproof::Comparison.new(before: missing, after: document(status: "PROVEN")).call
    assert_equal "comparison incomplete", result.fetch("status")
    incomplete = document(status: "PROVEN").merge(completeness: { observation: true, attribution: true, analysis: false })
    assert_equal "comparison incomplete", Branchproof::Comparison.new(before: incomplete, after: document(status: "PROVEN")).call.fetch("status")
  end

  def test_missing_nested_completeness_fields_are_incomplete
    incomplete = document(status: "PROVEN", completeness: { observation: true, attribution: true })

    result = Branchproof::Comparison.new(before: incomplete, after: document(status: "PROVEN")).call

    assert_equal "comparison incomplete", result.fetch("status")
    assert_includes result.fetch("reasons"), "run baselines are not successful finalized complete reports"
  end

  def test_analysis_absence_is_incomplete_even_when_baseline_is_finalized
    incomplete = document(status: "PROVEN").dup
    incomplete.delete(:analysis)

    result = Branchproof::Comparison.new(before: incomplete, after: document(status: "PROVEN")).call

    assert_equal "comparison incomplete", result.fetch("status")
  end

  def test_failed_baseline_is_incomplete
    result = Branchproof::Comparison.new(before: document(status: "PROVEN", baseline_status: "ERROR"),
                                         after: document(status: "PROVEN")).call

    assert_equal "comparison incomplete", result.fetch("status")
  end

  def test_runner_filter_limits_and_runtime_differences_are_context_reasons
    before = document(status: "PROVEN", run_metadata: {
                        runner_args: ["--name", "/one/"], limits: { exact_candidates: 10 }, runtime: { ruby: "3.4" }
                      })
    after = document(status: "PROVEN", run_metadata: {
                       runner_args: ["--name", "/two/"], limits: { exact_candidates: 20 }, runtime: { ruby: "3.5" }
                     })
    reasons = Branchproof::Comparison.new(before: before, after: after).call.fetch("reasons")

    assert_includes reasons, "runner_args differs"
    assert_includes reasons, "limits differs"
    assert_includes reasons, "runtime differs"
  end

  def test_different_test_population_is_allowed_when_discovery_context_matches
    before = document(status: "PROVEN")
    after = document(status: "PROVEN", tests: before.dig(:observations, :tests).first(1),
                     run_metadata: { test_files: ["test/decision_test.rb", "test/new_test.rb"] })

    result = Branchproof::Comparison.new(before: before, after: after).call

    refute_includes result.fetch("reasons"), "test_patterns differs"
    assert_equal "complete", result.fetch("status")
  end

  def test_zero_matches_and_source_population_changes_are_explicit
    no_match = document(status: "PROVEN").merge(source_inventory: { source_units: [], decisions: [] })
    result = Branchproof::Comparison.new(before: no_match, after: document(status: "PROVEN")).call
    assert_includes result.fetch("reasons"), "no comparable conditions"
    after = document(status: "PROVEN").merge(source_inventory: { source_units: [
                                               { source_id: "s1", relative_path: "lib/decision.rb", digest: "digest" },
                                               { source_id: "s2", relative_path: "lib/new.rb", digest: "new" }
                                             ], decisions: document(status: "PROVEN").dig(:source_inventory, :decisions) })
    result = Branchproof::Comparison.new(before: document(status: "PROVEN"), after: after).call
    assert_equal ["lib/new.rb"], result.fetch("newly_in_report")

    removed = document(status: "PROVEN").merge(source_inventory: { source_units: [], decisions: [] })
    result = Branchproof::Comparison.new(before: document(status: "PROVEN"), after: removed).call
    assert_equal ["lib/decision.rb"], result.fetch("no_longer_in_report")
  end

  def test_same_condition_id_with_disagreeing_source_identity_is_not_matched
    after_inventory = document(status: "PROVEN").fetch(:source_inventory).merge(
      source_units: [{ source_id: "different", relative_path: "lib/decision.rb", digest: "digest" }],
      decisions: [document(status: "PROVEN").dig(:source_inventory, :decisions).first.merge(source_id: "different")]
    )

    result = Branchproof::Comparison.new(before: document(status: "PROVEN"),
                                         after: document(status: "PROVEN", source_inventory: after_inventory)).call

    assert_equal 0, result.dig("matching", "matched_conditions")
    assert_includes result.fetch("reasons"), "no comparable conditions"
  end

  def test_test_location_line_shifts_match_unique_owner_and_report_context
    before = document(status: "PROVEN")
    before[:source_inventory][:source_units].first[:absolute_path] = "/old/checkout/lib/decision.rb"
    shifted_tests = before.dig(:observations, :tests).map do |test|
      test.merge(source: test.fetch(:source).merge(line: test.fetch(:source).fetch(:line) + 20))
    end
    after = document(status: "PROVEN", tests: shifted_tests)
    after[:source_inventory][:source_units].first[:absolute_path] = "/new/checkout/lib/decision.rb"

    change = Branchproof::Comparison.new(before: before, after: after).call.fetch("changes").find do |row|
      row.fetch("condition_id") == "c1"
    end
    owner = change.fetch("owner_context").find { |item| item.fetch("label").include?("test_true") }

    assert_equal "present in current run", owner.fetch("test_status")
    assert_equal "observed in current run", owner.fetch("observation_status")
    assert_equal [true, true], owner.fetch("values")
    assert_equal true, owner.fetch("outcome")
    refute_includes change.dig("previous_witness", 0, "tests", 0), "/old/checkout"
  end

  def test_ambiguous_duplicate_test_names_remain_unmatched
    duplicate_tests = [
      { id: "t1", adapter: "minitest", class_name: "DecisionTest", method_name: "test_true",
        source: { relative_path: "test/decision_test.rb", line: 8 } },
      { id: "t2", adapter: "minitest", class_name: "DecisionTest", method_name: "test_true",
        source: { relative_path: "test/decision_test.rb", line: 12 } },
      { id: "t3", adapter: "minitest", class_name: "DecisionTest", method_name: "test_false",
        source: { relative_path: "test/decision_test.rb", line: 16 } }
    ]
    before = document(status: "PROVEN", tests: duplicate_tests)
    after = document(status: "NOT_PROVEN", tests: duplicate_tests)

    change = Branchproof::Comparison.new(before: before, after: after).call.fetch("changes").find do |row|
      row.fetch("condition_id") == "c1"
    end

    owner = change.fetch("owner_context").find { |item| item.fetch("label").include?("test_true") }
    assert_equal "not observed in current run (no unique test match)", owner.fetch("test_status")
    assert_equal "not observed in current run", owner.fetch("observation_status")
  end

  def test_owner_observation_requires_matching_values_and_outcome
    before = document(status: "PROVEN")
    altered_vectors = [
      { id: "v1", decision_id: "d1", values: [true, false], outcome: false, test_ids: ["t1"] },
      { id: "v2", decision_id: "d1", values: [false, true], outcome: false, test_ids: ["t2"] }
    ]
    after = document(status: "NOT_PROVEN", vectors: altered_vectors)

    owner = Branchproof::Comparison.new(before: before, after: after).call.fetch("changes").first
                                   .fetch("owner_context").find { |item| item.fetch("label").include?("test_true") }
    assert_equal "present in current run", owner.fetch("test_status")
    assert_equal "not observed in current run", owner.fetch("observation_status")
  end
end
