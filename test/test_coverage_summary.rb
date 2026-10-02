# frozen_string_literal: true

require "test_helper"
require "branchproof/analyzer"
require "branchproof/coverage_summary"

class TestCoverageSummary < Minitest::Test
  def test_analyzer_uses_shared_summary_without_changing_its_coverage
    inventory = { decisions: [{ id: "d1", tree: { type: :atom, index: 0 },
                                conditions: [{ id: "c1", index: 0 }] }] }
    evidence = { vectors: [
      { id: "v1", decision_id: "d1", values: [false], outcome: false },
      { id: "v2", decision_id: "d1", values: [true], outcome: true }
    ] }
    result = Branchproof::Analyzer.new(inventory: inventory, evidence: evidence, limits: {}).call

    assert_equal result.fetch(:coverage), Branchproof::CoverageSummary.call(result.fetch(:decisions))
  end

  def test_shared_summary_preserves_boolean_flow_and_unsupported_arithmetic
    decisions = [
      { unsupported: false, coverage: { decision: { status: "covered" },
                                        condition_decision: { status: "partial" },
                                        condition: { covered_values: 2, required_values: 4,
                                                     covered_conditions: 1, condition_count: 2 },
                                        mcdc: { proven_conditions: 1 } },
        decision_table: { status: "calculated", covered_rules: 2,
                          required_rules: 3, generated_rules: 4,
                          impossible_rules: 1, coverage_status: "partial" } },
      { unsupported: true, coverage: { decision: { status: "unsupported" } }, decision_table: nil },
      { unsupported: false, kind: "multiway", coverage: { alternative: { covered_alternatives: 1,
                                                                         required_alternatives: 2 } } }
    ]

    summary = Branchproof::CoverageSummary.call(decisions)

    assert_equal({ covered_decisions: 1, supported_decisions: 1, percentage: 100 }, summary.fetch(:decision))
    assert_equal({ covered_values: 2, required_values: 4, covered_conditions: 1, condition_count: 2,
                   percentage: 50 }, summary.fetch(:condition))
    assert_equal({ decisions_analyzed: 1, not_calculated_decisions: 0, fully_covered_decisions: 0,
                   covered_rules: 2, required_rules: 3, generated_rules: 4, impossible_rules: 1,
                   percentage: 66.67, decision_percentage: 0.0 }, summary.fetch(:decision_table))
    assert_equal({ covered_alternatives: 1, required_alternatives: 2, supported_decisions: 1,
                   percentage: 50 }, summary.fetch(:alternative))
  end
end
