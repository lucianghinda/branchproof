# frozen_string_literal: true

require "test_helper"
require "branchproof/comparison"
require "branchproof/comparison_report"

class TestDecisionTableComparisonContract < Minitest::Test
  def test_json_regression_is_true_for_a_decision_table_coverage_loss
    before = document(table: table(rule_coverage: "covered"))
    after = document(table: table(rule_coverage: "missing"))

    result = Branchproof::Comparison.new(before: before, after: after).call

    assert_equal "complete", result.fetch("status")
    assert_equal true, result.fetch("regression")
    assert_equal 0, result.fetch("regressions")
    assert_equal 1, result.fetch("decision_table_regressions")
    assert_equal 1, Branchproof::ComparisonReport.new(document: result).exit_code(fail_on_regression: true)
  end

  def test_condition_regression_keeps_legacy_count_and_sets_json_regression
    before = document(condition_status: "PROVEN")
    after = document(condition_status: "NOT_PROVEN")

    result = Branchproof::Comparison.new(before: before, after: after).call

    assert_equal true, result.fetch("regression")
    assert_equal 1, result.fetch("regressions")
    assert_equal 0, result.fetch("decision_table_regressions")
  end

  def test_incomplete_comparison_stays_exit_two_even_when_it_has_a_loss
    before = document(table: table(rule_coverage: "covered"))
    after = document(table: table(rule_coverage: "missing")).tap do |report|
      report[:completeness][:analysis] = false
    end

    result = Branchproof::Comparison.new(before: before, after: after).call

    assert_equal "comparison incomplete", result.fetch("status")
    assert_equal false, result.fetch("regression")
    assert_equal 2, Branchproof::ComparisonReport.new(document: result).exit_code(fail_on_regression: true)
  end

  def test_table_schema_mismatch_is_context_and_preserves_condition_comparison
    before = document(condition_status: "PROVEN", table: table(schema_version: 1, rule_coverage: "covered"))
    after = document(table: table(schema_version: 2, rule_coverage: "missing"), condition_status: "NOT_PROVEN")

    result = Branchproof::Comparison.new(before: before, after: after).call

    assert_equal "comparison incomplete", result.fetch("status")
    assert_empty result.fetch("decision_table_changes")
    assert_includes result.fetch("decision_table_context_changes").map { |item| item.fetch("reason") },
                    "decision-table schema version changed"
    assert_equal 1, result.fetch("regressions")
  end

  def test_one_sided_table_reports_rule_set_context
    before = document(table: table(rule_coverage: "covered"))
    after = document(table: nil)

    result = Branchproof::Comparison.new(before: before, after: after).call

    assert_includes result.fetch("decision_table_context_changes").map { |item| item.fetch("reason") },
                    "decision-table rule set changed"
  end

  def test_legacy_missing_reachability_metadata_does_not_create_mode_context
    before = document(table: table(reachability_analyzed: nil))
    after = document(table: table(reachability_analyzed: true))

    result = Branchproof::Comparison.new(before: before, after: after).call

    refute_includes result.fetch("decision_table_context_changes").map { |item| item.fetch("reason") },
                    "reachability analysis mode changed"
  end

  def test_ordinary_coverage_gain_does_not_create_analysis_context
    before = document(table: table(rule_coverage: "missing", rule_reachability: "unknown"))
    after = document(table: table(rule_coverage: "covered", rule_reachability: "observed"))

    result = Branchproof::Comparison.new(before: before, after: after).call

    refute_includes result.fetch("decision_table_context_changes").map { |item| item.fetch("reason") },
                    "rule reachability changed alongside coverage"
  end

  def test_analysis_and_reachability_mode_changes_are_explicit_context
    before = document(table: table(constraint_analysis_version: 1, reachability_analyzed: false,
                                   rule_reachability: "unknown"))
    after = document(table: table(constraint_analysis_version: 2, reachability_analyzed: true,
                                  rule_reachability: "statically_impossible"))

    result = Branchproof::Comparison.new(before: before, after: after).call
    reasons = result.fetch("decision_table_context_changes").map { |item| item.fetch("reason") }

    assert_includes reasons, "constraint analysis version changed"
    assert_includes reasons, "reachability analysis mode changed"
    refute_includes result.fetch("decision_table_changes").map { |item| item.fetch("change") }, "rule coverage gained"
  end

  def test_same_unsupported_table_schema_is_not_reported_as_unchanged
    before = document(table: table(schema_version: 2))
    after = document(table: table(schema_version: 2, rule_coverage: "covered"))

    result = Branchproof::Comparison.new(before: before, after: after).call

    assert_empty result.fetch("decision_table_changes")
    assert_includes result.fetch("decision_table_context_changes").map { |item| item.fetch("reason") },
                    "decision-table schema version unsupported"
  end

  def test_unknown_to_impossible_is_analysis_change_and_covered_to_excluded_keeps_loss
    before = document(table: table(rule_coverage: "covered", rule_reachability: "unknown"))
    after = document(table: table(rule_coverage: "excluded", rule_reachability: "statically_impossible"))

    result = Branchproof::Comparison.new(before: before, after: after).call
    change = result.fetch("decision_table_changes").first

    assert_equal "rule coverage lost", change.fetch("change")
    assert_equal 1, result.fetch("decision_table_regressions")
    assert_includes result.fetch("decision_table_context_changes").map { |item| item.fetch("reason") },
                    "rule reachability changed alongside coverage"
  end

  private

  def document(condition_status: "NOT_PROVEN", table: table(rule_coverage: "missing"))
    decision = { decision_id: "d1", condition_results: [{ condition_id: "c1", status: condition_status }] }
    decision[:decision_table] = table if table
    {
      schema_version: "1.1", criterion_version: "masking_occurrence_v1",
      source_inventory: {
        source_units: [{ source_id: "s1", relative_path: "lib/decision.rb", digest: "same" }],
        decisions: [{ id: "d1", source_id: "s1", expression: "flag", line: 4,
                      conditions: [{ id: "c1", index: 0, expression: "flag", byte_start: 0, byte_length: 4 }] }]
      },
      observations: { run_ids: ["run"], vectors: [], tests: [],
                      completeness: { observation: true, attribution: true,
                                      analysis: true } },
      analysis: { decisions: [decision],
                  completeness: { observation: true, attribution: true,
                                  analysis: true } },
      baseline: { status: "PASSED", finalized: true },
      completeness: { observation: true, attribution: true, analysis: true },
      runtime: "ruby-4.0",
      run_metadata: { project_kind: "ruby", source_patterns: ["lib/**/*.rb"], test_patterns: ["test/**/*_test.rb"],
                      test_files: [], runner_args: [], limits: {} }
    }
  end

  def table(schema_version: 1, constraint_analysis_version: 1, reachability_analyzed: true,
            rule_coverage: "missing", rule_reachability: "unknown")
    { status: "calculated", schema_version: schema_version,
      constraint_analysis_version: constraint_analysis_version,
      reachability_analyzed: reachability_analyzed,
      rules: [{ id: "r1", label: "R1", conditions: ["true"], outcome: true,
                coverage: rule_coverage, reachability: rule_reachability }] }
  end
end
