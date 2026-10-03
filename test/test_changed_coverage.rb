# frozen_string_literal: true

require "test_helper"
require "branchproof/changed_coverage"

class TestChangedCoverage < Minitest::Test
  def scope(decision_ids: ["d1"], status: "complete")
    { status: status, decision_ids: decision_ids }
  end

  def document(decisions:, baseline: { status: "PASSED", finalized: true }, complete: true, analysis: true)
    section = { observation: complete, attribution: complete, analysis: analysis }
    { baseline: baseline, completeness: section,
      observations: { completeness: section },
      analysis: { decisions: decisions, completeness: section } }
  end

  def decision(id: "d1", unsupported: false, coverage: nil, decision_table: nil)
    { decision_id: id, unsupported: unsupported,
      coverage: coverage || {
        decision: { status: "covered" }, condition: { covered_values: 2, condition_count: 1,
                                                      covered_conditions: 1 },
        condition_decision: { status: "covered" }, mcdc: { proven_conditions: 1 },
        decision_table: { status: "covered", covered_rules: 2, required_rules: 2,
                          generated_rules: 2, impossible_rules: 0 }
      }, decision_table: decision_table || { status: "calculated", coverage_status: "covered",
                                             covered_rules: 2, required_rules: 2,
                                             generated_rules: 2, impossible_rules: 0 } }
  end

  def test_aggregates_only_selected_decisions_and_returns_six_coverage_rows
    report = document(decisions: [decision, decision(id: "d2", coverage: {})])

    result = Branchproof::ChangedCoverage.call(document: report, scope: scope)

    assert_equal "available", result.fetch(:status)
    assert_equal 1, result.fetch(:selected_decisions)
    assert_equal 1, result.fetch(:supported_decisions)
    assert_equal 0, result.fetch(:unsupported_decisions)
    assert_equal %i[decision condition condition_decision mcdc decision_table alternative],
                 result.fetch(:coverage).keys
    assert_equal 100, result.dig(:coverage, :decision, :percentage)
    assert_equal "unavailable", result.dig(:coverage, :alternative, :status)
    assert_equal "zero_denominator", result.dig(:coverage, :alternative, :reason)
  end

  def test_subset_totals_mix_boolean_flow_and_unsupported_decisions
    flow = { decision_id: "flow", kind: "multiway", unsupported: false,
             coverage: { alternative: { covered_alternatives: 1, required_alternatives: 2 },
                         mcdc: { status: "not_applicable" } } }
    unsupported = decision(id: "unsupported", unsupported: true)
    report = document(decisions: [decision, flow, unsupported, decision(id: "off_scope")])

    result = Branchproof::ChangedCoverage.call(
      document: report, scope: scope(decision_ids: %w[d1 flow unsupported])
    )

    assert_equal 3, result.fetch(:selected_decisions)
    assert_equal 2, result.fetch(:supported_decisions)
    assert_equal 1, result.fetch(:unsupported_decisions)
    assert_equal [1, 1], [result.dig(:coverage, :decision, :numerator),
                          result.dig(:coverage, :decision, :denominator)]
    assert_equal [1, 2], [result.dig(:coverage, :alternative, :numerator),
                          result.dig(:coverage, :alternative, :denominator)]
  end

  def test_empty_and_unsupported_only_scopes_never_report_percentages
    unsupported = decision(unsupported: true)
    [scope(decision_ids: [], status: "empty"), scope(decision_ids: ["d1"])].each do |selected_scope|
      report = document(decisions: [unsupported])

      result = Branchproof::ChangedCoverage.call(document: report, scope: selected_scope)

      assert_equal "unavailable", result.fetch(:status)
      assert(result.fetch(:coverage).values.all? { |row| row[:percentage].nil? })
    end
  end

  def test_incomplete_runs_suppress_percentages_and_uncalculated_table_is_local
    table = decision(decision_table: { status: "not_calculated", reason: "decision_table_unavailable" })
    report = document(decisions: [table], complete: false)

    result = Branchproof::ChangedCoverage.call(document: report, scope: scope)

    assert_equal "unavailable", result.fetch(:status)
    assert(result.fetch(:coverage).values.all? { |row| row[:percentage].nil? })

    complete_result = Branchproof::ChangedCoverage.call(document: document(decisions: [table]), scope: scope)
    assert_equal "available", complete_result.fetch(:coverage).fetch(:decision).fetch(:status)
    assert_equal "unavailable", complete_result.dig(:coverage, :decision_table, :status)
    assert_equal "available", complete_result.dig(:coverage, :condition, :status)
  end

  def test_missing_selected_analysis_makes_scope_unavailable
    result = Branchproof::ChangedCoverage.call(document: document(decisions: []), scope: scope)

    assert_equal "unavailable", result.fetch(:status)
    assert_equal "missing_selected_analysis", result.fetch(:reason)
  end

  def test_missing_per_decision_coverage_counts_makes_scope_unavailable
    result = Branchproof::ChangedCoverage.call(document: document(decisions: [{ decision_id: "d1" }]),
                                               scope: scope)

    assert_equal "missing_selected_coverage", result.fetch(:reason)
    assert(result.fetch(:coverage).values.all? { |row| row[:percentage].nil? })
  end

  def test_malformed_per_decision_counts_are_unavailable_without_raising
    malformed = decision
    malformed[:coverage][:condition][:condition_count] = []

    result = Branchproof::ChangedCoverage.call(document: document(decisions: [malformed]), scope: scope)

    assert_equal "missing_selected_coverage", result.fetch(:reason)
    assert(result.fetch(:coverage).values.all? { |row| row[:percentage].nil? })
  end

  def test_impossible_per_decision_fractions_are_unavailable
    impossible = decision
    impossible[:coverage][:condition][:covered_values] = 3
    impossible[:coverage][:mcdc][:proven_conditions] = 2

    result = Branchproof::ChangedCoverage.call(document: document(decisions: [impossible]), scope: scope)

    assert_equal "missing_selected_coverage", result.fetch(:reason)
    assert_nil result.dig(:coverage, :condition, :percentage)
    assert_nil result.dig(:coverage, :mcdc, :percentage)
  end

  def test_failed_baseline_never_publishes_percentages
    report = document(decisions: [decision], baseline: { status: "FAILED", finalized: true })

    result = Branchproof::ChangedCoverage.call(document: report, scope: scope)

    assert_equal "baseline_unavailable", result.fetch(:reason)
    assert(result.fetch(:coverage).values.all? { |row| row[:percentage].nil? })
  end
end
