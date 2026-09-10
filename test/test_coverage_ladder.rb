# frozen_string_literal: true

require "test_helper"
require "branchproof/analyzer"

class TestCoverageLadder < Minitest::Test
  def atom(index) = { type: :atom, index: index }

  def analyze(tree, vectors, decision: nil)
    decision ||= { id: "d", tree: tree,
                   conditions: tree_leaves(tree).map { |index| { id: "c#{index}", index: index } } }
    Branchproof::Analyzer.new(inventory: { decisions: [decision] }, evidence: { vectors: vectors }, limits: {}).call
  end

  def tree_leaves(tree)
    return [tree[:index]] if tree[:type].to_sym == :atom

    tree_leaves(tree[:left]) + tree_leaves(tree[:right])
  end

  def test_reports_decision_and_condition_ladders_with_provenance
    tree = { type: :and, left: atom(0), right: atom(1) }
    vectors = [
      { "id" => "f", "decision_id" => "d", "values" => [false, nil], "outcome" => false,
        "test_ids" => %w[z z], "unattributed_count" => 2 },
      { id: "t", decision_id: "d", values: [true, true], outcome: true, test_ids: ["a"] }
    ]
    result = analyze(tree, vectors)
    decision = result.fetch(:decisions).first

    assert_equal "covered", decision.dig(:coverage, :decision, :status)
    assert_equal ["f"], decision.dig(:coverage, :decision, :outcomes).find { |row| row[:value] == false }[:vector_ids]
    assert_equal %w[a z], decision.dig(:coverage, :decision, :outcomes).flat_map { |row| row[:test_ids] }.uniq.sort
    assert_equal 3, decision.dig(:coverage, :condition, :covered_values)
    assert_equal "partial", decision.dig(:coverage, :condition_decision, :status)
    assert_equal 100.0, result.dig(:coverage, :decision, :percentage)
    assert_equal 75.0, result.dig(:coverage, :condition, :percentage)
    assert_equal ["f"], decision.dig(:condition_results, 0, :coverage, :values).find { |row| row[:value] == false }[:vector_ids]
  end

  def test_masked_conditions_only_cover_evaluated_values_and_short_circuit_is_neither
    tree = { type: :or, left: atom(0), right: atom(1) }
    result = analyze(tree, [{ id: "v", decision_id: "d", values: [true, nil], outcome: true }])
    decision = result.fetch(:decisions).first

    assert_equal 1, decision.dig(:coverage, :condition, :covered_values)
    assert_equal "partial", decision.dig(:coverage, :condition, :status)
    assert_equal 1, decision.dig(:condition_results, 0, :coverage, :covered_values)
    assert_equal "unexecuted", decision.dig(:condition_results, 1, :coverage, :status)
  end

  def test_empty_supported_decision_is_unexecuted_and_unsupported_is_excluded
    tree = { type: :and, left: atom(0), right: atom(1) }
    empty = analyze(tree, []).fetch(:decisions).first
    assert_equal "unexecuted", empty.dig(:coverage, :decision, :status)
    assert_equal 0.0, analyze(tree, []).dig(:coverage, :decision, :percentage)

    unsupported = analyze(tree, [], decision: { id: "d", tree: tree, support_status: "unsupported", conditions: [] })
    decision = unsupported.fetch(:decisions).first
    assert_equal "unsupported", decision.dig(:coverage, :decision, :status)
    assert_equal 0, unsupported.dig(:coverage, :decision, :supported_decisions)
    assert_nil unsupported.dig(:coverage, :decision, :percentage)
  end

  def test_condition_decision_can_be_full_while_mcdc_remains_partial
    tree = { type: :or, left: { type: :and, left: atom(0), right: atom(1) }, right: atom(2) }
    vectors = [
      { id: "tf-f", decision_id: "d", values: [true, false, false], outcome: false },
      { id: "f-t", decision_id: "d", values: [false, nil, true], outcome: true },
      { id: "tt-t", decision_id: "d", values: [true, true, nil], outcome: true }
    ]
    result = analyze(tree, vectors)
    decision = result.fetch(:decisions).first

    assert_equal "covered", decision.dig(:coverage, :decision, :status)
    assert_equal "covered", decision.dig(:coverage, :condition, :status)
    assert_equal "covered", decision.dig(:coverage, :condition_decision, :status)
    assert_equal "partial", decision.dig(:coverage, :mcdc, :status)
    assert_equal 2, decision.dig(:coverage, :mcdc, :proven_conditions)
    assert_equal 100.0, result.dig(:coverage, :condition_decision, :percentage)
    assert_equal 66.67, result.dig(:coverage, :mcdc, :percentage)
  end

  def test_invalid_and_incomplete_vectors_do_not_contribute_coverage
    tree = { type: :and, left: atom(0), right: atom(1) }
    result = analyze(tree, [
                       { id: "bad", decision_id: "d", values: [true, true], outcome: false },
                       { id: "incomplete", decision_id: "d", values: [true, true], outcome: true, status: "aborted" }
                     ])
    coverage = result.dig(:decisions, 0, :coverage)
    assert_equal "unexecuted", coverage.dig(:decision, :status)
    assert_empty(coverage.dig(:decision, :outcomes).flat_map { |row| row[:vector_ids] })
  end

  def test_reports_all_four_ladders_as_covered_for_f_tf_tt
    tree = { type: :and, left: atom(0), right: atom(1) }
    result = analyze(tree, [
                       { id: "f", decision_id: "d", values: [false, nil], outcome: false },
                       { id: "tf", decision_id: "d", values: [true, false], outcome: false },
                       { id: "tt", decision_id: "d", values: [true, true], outcome: true }
                     ])
    decision = result.fetch(:decisions).first
    coverage = decision.fetch(:coverage)
    aggregate = result.fetch(:coverage)

    assert_equal(%w[covered covered covered covered], %i[decision condition condition_decision mcdc].map { |key| coverage.dig(key, :status) })
    assert_equal [2, 2], [coverage.dig(:decision, :covered_outcomes), coverage.dig(:decision, :required_outcomes)]
    assert_equal [4, 4, 2, 2], [coverage.dig(:condition, :covered_values), coverage.dig(:condition, :required_values),
                                coverage.dig(:condition, :covered_conditions), coverage.dig(:condition, :condition_count)]
    assert_equal [2, 2], [coverage.dig(:mcdc, :proven_conditions), coverage.dig(:mcdc, :condition_count)]
    assert_equal [1, 1], [aggregate.dig(:decision, :covered_decisions), aggregate.dig(:decision, :supported_decisions)]
    assert_equal [4, 4, 2, 2], [aggregate.dig(:condition, :covered_values), aggregate.dig(:condition, :required_values),
                                aggregate.dig(:condition, :covered_conditions), aggregate.dig(:condition, :condition_count)]
    assert_equal [1, 1], [aggregate.dig(:condition_decision, :covered_decisions), aggregate.dig(:condition_decision, :supported_decisions)]
    assert_equal [2, 2], [aggregate.dig(:mcdc, :proven_conditions), aggregate.dig(:mcdc, :supported_conditions)]
    assert_equal([100.0, 100.0, 100.0, 100.0], %i[decision condition condition_decision mcdc].map { |key| aggregate.dig(key, :percentage) })
  end

  def test_mixed_aggregate_counts_only_supported_decisions_and_conditions
    tree = { type: :and, left: atom(0), right: atom(1) }
    full = { id: "full", tree: tree, conditions: [{ id: "full-a", index: 0 }, { id: "full-b", index: 1 }] }
    empty = { id: "empty", tree: atom(0), conditions: [{ id: "empty-a", index: 0 }] }
    unsupported = { id: "unsupported", tree: tree, support_status: "unsupported",
                    conditions: [{ id: "unsupported-a", index: 0 }, { id: "unsupported-b", index: 1 },
                                 { id: "unsupported-c", index: 2 }] }
    result = Branchproof::Analyzer.new(
      inventory: { decisions: [full, empty, unsupported] },
      evidence: { vectors: [
        { id: "f", decision_id: "full", values: [false, nil], outcome: false },
        { id: "tf", decision_id: "full", values: [true, false], outcome: false },
        { id: "tt", decision_id: "full", values: [true, true], outcome: true }
      ] }, limits: {}
    ).call
    aggregate = result.fetch(:coverage)

    assert_equal [1, 2], [aggregate.dig(:decision, :covered_decisions), aggregate.dig(:decision, :supported_decisions)]
    assert_equal [4, 6, 2, 3], [aggregate.dig(:condition, :covered_values), aggregate.dig(:condition, :required_values),
                                aggregate.dig(:condition, :covered_conditions), aggregate.dig(:condition, :condition_count)]
    assert_equal [1, 2], [aggregate.dig(:condition_decision, :covered_decisions), aggregate.dig(:condition_decision, :supported_decisions)]
    assert_equal [2, 3], [aggregate.dig(:mcdc, :proven_conditions), aggregate.dig(:mcdc, :supported_conditions)]
    assert_equal([50.0, 66.67, 50.0, 66.67], %i[decision condition condition_decision mcdc].map { |key| aggregate.dig(key, :percentage) })
  end

  def test_reports_explicit_missing_false_values
    tree = { type: :and, left: atom(0), right: atom(1) }
    result = analyze(tree, [{ id: "tt", decision_id: "d", values: [true, true], outcome: true }])
    decision = result.fetch(:decisions).first

    assert_equal [1, 2, [false]], [decision.dig(:coverage, :decision, :covered_outcomes),
                                   decision.dig(:coverage, :decision, :required_outcomes),
                                   decision.dig(:coverage, :decision, :missing_outcomes)]
    assert_equal([[false], [false]], decision[:condition_results].map { |result| result.dig(:coverage, :missing_values) })
  end

  def test_counts_an_actually_evaluated_masked_true_condition
    tree = { type: :and, left: atom(0), right: atom(1) }
    decision = analyze(tree, [{ id: "tf", decision_id: "d", values: [true, false], outcome: false }]).fetch(:decisions).first
    first_condition = decision.fetch(:condition_results).first.fetch(:coverage)

    assert_equal true, first_condition[:true_observed]
    assert_equal false, first_condition[:false_observed]
    assert_equal 1, first_condition[:covered_values]
    assert_equal [2], decision.fetch(:effective_masks_by_vector).values.map(&:to_i)
  end

  def test_distinguishes_executed_without_proof_from_empty_execution_across_all_ladders
    tree = { type: :and, left: atom(0), right: atom(1) }
    executed = analyze(tree, [{ id: "tt", decision_id: "d", values: [true, true], outcome: true }]).fetch(:decisions).first.fetch(:coverage)
    empty = analyze(tree, []).fetch(:decisions).first.fetch(:coverage)

    assert_equal(%w[partial partial partial partial], %i[decision condition condition_decision mcdc].map { |key| executed.dig(key, :status) })
    assert_equal(%w[unexecuted unexecuted unexecuted unexecuted], %i[decision condition condition_decision mcdc].map { |key| empty.dig(key, :status) })
    assert_equal [1, 2, 2, 4, 0, 2], [executed.dig(:decision, :covered_outcomes), executed.dig(:decision, :required_outcomes),
                                      executed.dig(:condition, :covered_values), executed.dig(:condition, :required_values),
                                      executed.dig(:mcdc, :proven_conditions), executed.dig(:mcdc, :condition_count)]
  end

  def test_deduplicates_and_sorts_provenance_per_value_bucket
    tree = { type: :or, left: { type: :and, left: atom(0), right: atom(1) }, right: atom(2) }
    result = analyze(tree, [
                       { id: "t1", decision_id: "d", values: [true, true, nil], outcome: true, test_ids: %w[z a z], unattributed_count: 2 },
                       { id: "t2", decision_id: "d", values: [true, false, true], outcome: true, test_ids: %w[b a], unattributed_count: 1 },
                       { id: "t3", decision_id: "d", values: [false, nil, true], outcome: true, test_ids: %w[y a], unattributed_count: 5 },
                       { id: "f1", decision_id: "d", values: [false, nil, false], outcome: false, test_ids: %w[d c d], unattributed_count: 3 },
                       { id: "f2", decision_id: "d", values: [true, false, false], outcome: false, test_ids: %w[c e], unattributed_count: 4 }
                     ])
    decision = result.fetch(:decisions).first
    outcomes = decision.dig(:coverage, :decision, :outcomes).to_h { |row| [row[:value], row] }
    conditions = decision.fetch(:condition_results).map { |result| result.fetch(:coverage).fetch(:values).to_h { |row| [row[:value], row] } }

    assert_equal %w[a b y z], outcomes[true][:test_ids]
    assert_equal %w[c d e], outcomes[false][:test_ids]
    assert_equal [%w[t1 t2 t3], %w[f1 f2]], [outcomes[true][:vector_ids], outcomes[false][:vector_ids]]
    assert_equal [8, 7], [outcomes[true][:unattributed_count], outcomes[false][:unattributed_count]]
    assert_equal %w[a b c e z], conditions[0][true][:test_ids]
    assert_equal %w[a c d y], conditions[0][false][:test_ids]
    assert_equal [7, 8], [conditions[0][true][:unattributed_count], conditions[0][false][:unattributed_count]]
  end

  def test_excludes_incompatible_sources_and_malformed_extra_observations
    tree = { type: :and, left: atom(0), right: atom(1) }
    decision = { id: "d", source_id: "source", tree: tree,
                 conditions: [{ id: "a", index: 0 }, { id: "b", index: 1 }] }
    result = Branchproof::Analyzer.new(
      inventory: { decisions: [decision] },
      evidence: { vectors: [
        { id: "wrong-source", decision_id: "d", source_id: "other", values: [true, true], outcome: true },
        { id: "extra", decision_id: "d", source_id: "source", values: [true, true, false], outcome: true }
      ] }, limits: {}
    ).call
    coverage = result.dig(:decisions, 0, :coverage)

    assert_equal(%w[unexecuted unexecuted unexecuted unexecuted], %i[decision condition condition_decision mcdc].map { |key| coverage.dig(key, :status) })
    assert_empty(coverage.dig(:decision, :outcomes).flat_map { |row| row[:vector_ids] })
    assert_equal 0, coverage.dig(:condition, :covered_values)
  end

  def test_empty_inventory_has_nil_percentages_for_all_aggregates
    result = Branchproof::Analyzer.new(inventory: { decisions: [] }, evidence: { vectors: [] }, limits: {}).call
    coverage = result.fetch(:coverage)

    assert_equal([nil, nil, nil, nil], %i[decision condition condition_decision mcdc].map { |key| coverage.dig(key, :percentage) })
    assert_equal [0, 0, 0, 0], [coverage.dig(:decision, :covered_decisions), coverage.dig(:decision, :supported_decisions),
                                coverage.dig(:condition, :covered_values), coverage.dig(:mcdc, :proven_conditions)]
  end
end
