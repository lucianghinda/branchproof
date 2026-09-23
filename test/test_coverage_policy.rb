# frozen_string_literal: true

require "test_helper"
require "branchproof/coverage_policy"
require "branchproof/report"
require "json"
require "stringio"

class TestCoveragePolicy < Minitest::Test
  CRITERIA = %w[decision condition condition_decision mcdc decision_table].freeze
  COMPLETE = { observation: true, attribution: true, analysis: true }.freeze

  def test_normalize_accepts_string_and_symbol_keys_and_returns_canonical_keys
    assert_equal({ "decision" => 80, "mcdc" => 66.67 },
                 Branchproof::CoveragePolicy.normalize(decision: 80, "mcdc" => 66.67))
  end

  def test_normalize_rejects_unknown_and_duplicate_canonical_keys
    assert_raises(ArgumentError) { Branchproof::CoveragePolicy.normalize(other: 80) }
    assert_raises(ArgumentError) { Branchproof::CoveragePolicy.normalize(mcdc: 80, "mcdc" => 90) }
  end

  def test_normalize_rejects_non_hash_non_finite_non_numeric_or_out_of_range_minima
    [nil, [], "80"].each do |minimum|
      assert_raises(ArgumentError) { Branchproof::CoveragePolicy.normalize(minimum) }
    end
    [Float::NAN, Float::INFINITY, -Float::INFINITY, Complex(80, 0), "80", -1, 101].each do |threshold|
      assert_raises(ArgumentError) { Branchproof::CoveragePolicy.normalize(mcdc: threshold) }
    end
  end

  def test_each_criterion_passes_at_exact_threshold_and_fails_below_it
    counts = {
      "decision" => { "covered_decisions" => 4, "supported_decisions" => 5 },
      "condition" => { "covered_values" => 4, "required_values" => 5 },
      "condition_decision" => { "covered_decisions" => 4, "supported_decisions" => 5 },
      "mcdc" => { "proven_conditions" => 4, "supported_conditions" => 5 },
      "decision_table" => { "covered_rules" => 4, "required_rules" => 5,
                            "not_calculated_decisions" => 0 }
    }

    CRITERIA.each do |criterion|
      exact = Branchproof::CoveragePolicy.new(minimum: { criterion => 80 }).call(document: document(counts))
      assert_equal "passed", exact[:status], criterion
      assert_equal "passed", exact[:gates].first[:status], criterion
      assert_nil exact[:gates].first[:reason], criterion

      failed = Branchproof::CoveragePolicy.new(minimum: { criterion => 81 }).call(document: document(counts))
      assert_equal "failed", failed[:status], criterion
      assert_equal "failed", failed[:gates].first[:status], criterion
      assert_nil failed[:gates].first[:reason], criterion
    end
  end

  def test_threshold_comparison_does_not_round_percentage
    result = Branchproof::CoveragePolicy.new(minimum: { mcdc: 66.67 }).call(
      document: document({ "mcdc" => { "proven_conditions" => 2, "supported_conditions" => 3 } })
    )

    assert_equal "failed", result[:status]
    assert_equal [2, 3, 66.67], result[:gates].first.values_at(:numerator, :denominator, :minimum)
  end

  def test_symbol_and_string_keyed_documents_produce_the_same_gate
    symbol_document = document({ mcdc: { proven_conditions: 2, supported_conditions: 3 } })
    string_document = JSON.parse(JSON.generate(symbol_document))
    policy = Branchproof::CoveragePolicy.new(minimum: { mcdc: 66.67 })

    assert_equal policy.call(document: string_document), policy.call(document: symbol_document)
  end

  def test_evaluates_a_report_generated_document_with_analyzer_completeness
    analysis = { coverage: { mcdc: { proven_conditions: 2, supported_conditions: 3 } }, completeness: COMPLETE }
    report = Branchproof::Report.new(
      inventory: { decisions: [] }, evidence: { vectors: [], completeness: COMPLETE }, analysis: analysis,
      minima: [], baseline: { status: "PASSED", finalized: true }, diagnostics: []
    )
    output = StringIO.new
    report.write(io: output, format: :json)
    generated_document = JSON.parse(output.string)

    assert_equal({ "observation" => true, "attribution" => true, "analysis" => true },
                 generated_document.fetch("completeness"))
    assert_equal({ "observation" => true, "attribution" => true, "analysis" => true },
                 generated_document.fetch("analysis").fetch("completeness"))
    assert_equal "passed", Branchproof::CoveragePolicy.new(minimum: { mcdc: 66.0 }).call(
      document: generated_document
    ).fetch(:status)
  end

  def test_empty_policy_is_passed_without_needing_a_document
    result = Branchproof::CoveragePolicy.new(minimum: {}).call(document: nil)

    assert_equal({ minimum: {}, status: "passed", gates: [] }, result)
  end

  def test_gate_is_unavailable_for_missing_invalid_or_zero_denominator_counts
    [
      [{}, "missing_coverage_count"],
      [{ "covered_decisions" => "1", "supported_decisions" => 2 }, "invalid_coverage_count"],
      [{ "covered_decisions" => 0, "supported_decisions" => 0 }, "zero_denominator"]
    ].each do |coverage, reason|
      result = policy_result("decision", coverage)

      assert_equal "unavailable", result[:status], reason
      assert_equal "unavailable", result[:gates].first[:status], reason
      assert_equal reason, result[:gates].first[:reason], reason
    end
  end

  def test_incomplete_or_unsuccessful_baseline_makes_failed_gate_unavailable
    [
      [document({ "mcdc" => { "proven_conditions" => 0, "supported_conditions" => 1 } },
                baseline: { status: "PASSED", finalized: false }), "baseline_unavailable"],
      [document({ "mcdc" => { "proven_conditions" => 0, "supported_conditions" => 1 } },
                baseline: { status: "FAILED", finalized: true }), "baseline_unavailable"],
      [document({ "mcdc" => { "proven_conditions" => 0, "supported_conditions" => 1 } },
                completeness: { observation: false, attribution: true, analysis: true }), "incomplete_document"],
      [document({ "mcdc" => { "proven_conditions" => 0, "supported_conditions" => 1 } },
                observations: { completeness: { observation: true, attribution: false, analysis: true } }),
       "incomplete_observations"],
      [document({ "mcdc" => { "proven_conditions" => 0, "supported_conditions" => 1 } },
                analysis: { completeness: { observation: true, attribution: true, analysis: false },
                            coverage: { "mcdc" => { "proven_conditions" => 0, "supported_conditions" => 1 } } }),
       "incomplete_analysis"]
    ].each do |doc, reason|
      result = Branchproof::CoveragePolicy.new(minimum: { mcdc: 80 }).call(document: doc)

      assert_equal "unavailable", result[:status], reason
      assert_equal "unavailable", result[:gates].first[:status], reason
      assert_equal reason, result[:gates].first[:reason], reason
    end
  end

  def test_decision_table_partial_calculation_is_unavailable
    coverage = { "covered_rules" => 10, "required_rules" => 10, "not_calculated_decisions" => 1 }
    result = policy_result("decision_table", coverage)

    assert_equal "unavailable", result[:status]
    assert_equal "decision_table_not_calculated", result[:gates].first[:reason]
  end

  def test_unavailable_gate_wins_over_a_failed_gate
    coverage = {
      "decision" => { "covered_decisions" => 0, "supported_decisions" => 1 },
      "mcdc" => { "proven_conditions" => 1, "supported_conditions" => 0 }
    }
    doc = document(coverage)
    result = Branchproof::CoveragePolicy.new(minimum: { decision: 80, mcdc: 80 }).call(document: doc)

    assert_equal "unavailable", result[:status]
    statuses = result[:gates].map { |gate| gate[:status] }
    assert_equal %w[failed unavailable], statuses
  end

  private

  def policy_result(criterion, coverage)
    Branchproof::CoveragePolicy.new(minimum: { criterion => 80 }).call(
      document: document({ criterion => coverage })
    )
  end

  def document(coverage = {}, baseline: { status: "PASSED", finalized: true },
               completeness: COMPLETE, observations: { completeness: COMPLETE },
               analysis: { completeness: COMPLETE, coverage: coverage })
    { baseline: baseline, completeness: completeness, observations: observations, analysis: analysis }
  end
end
