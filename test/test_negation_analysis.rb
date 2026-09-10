# frozen_string_literal: true

require "test_helper"
require "branchproof/analyzer"
require "branchproof/evidence"

class TestNegationAnalysis < Minitest::Test
  def atom(index)
    { type: :atom, index: index }
  end

  def not_tree(child)
    { type: :not, child: child }
  end

  def inventory_for(tree, count)
    { decisions: [{ id: "d", tree: tree,
                    conditions: (0...count).map { |index| { id: "c#{index}", index: index } } }] }
  end

  def analyze(tree, vectors, count)
    Branchproof::Analyzer.new(inventory: inventory_for(tree, count), evidence: { vectors: vectors }, limits: {}).call
  end

  def test_not_inverts_outcome_and_preserves_effectiveness
    tree = not_tree(atom(0))
    vectors = [
      { id: "false", decision_id: "d", values: [false], outcome: true },
      { id: "true", decision_id: "d", values: [true], outcome: false }
    ]

    decision = analyze(tree, vectors, 1).fetch(:decisions).first

    assert_equal({ "false" => 1, "true" => 1 }, decision.fetch(:effective_masks_by_vector))
    assert_equal "PROVEN", decision.fetch(:condition_results).first.fetch(:status)
    assert_equal %w[false true], decision.fetch(:condition_results).first.fetch(:canonical_pair)
  end

  def test_not_over_short_circuit_tree_keeps_masks_and_mcdc_pairs
    tree = not_tree({ type: :and, left: atom(0), right: atom(1) })
    vectors = [
      { id: "a-false", decision_id: "d", values: [false, nil], outcome: true },
      { id: "a-true-b-false", decision_id: "d", values: [true, false], outcome: true },
      { id: "both-true", decision_id: "d", values: [true, true], outcome: false }
    ]

    decision = analyze(tree, vectors, 2).fetch(:decisions).first

    assert_equal({ "a-false" => 1, "a-true-b-false" => 2, "both-true" => 3 },
                 decision.fetch(:effective_masks_by_vector))
    assert_equal(%w[PROVEN PROVEN], decision.fetch(:condition_results).map { |item| item.fetch(:status) })
    assert_equal "covered", decision.dig(:coverage, :mcdc, :status)
  end

  def test_not_constraint_search_finds_a_counterpart_through_negated_tree
    tree = not_tree({ type: :and, left: atom(0), right: atom(1) })
    analyzer = Branchproof::Analyzer.new(
      inventory: inventory_for(tree, 2),
      evidence: { vectors: [{ id: "observed", decision_id: "d", values: [false, nil], outcome: true }] },
      limits: {}
    )

    missing = analyzer.missing(decision_id: "d", condition_index: 1)

    assert_equal "CANDIDATE", missing.fetch(:status)
    assert_equal [true, true], missing.fetch(:candidate_vectors).first.fetch(:values)
    assert_equal false, missing.fetch(:candidate_vectors).first.fetch(:outcome)
  end

  def test_not_graph_routes_child_exits_to_inverted_destinations
    tree = not_tree({ type: :and, left: atom(0), right: atom(1) })
    decision = analyze(tree, [], 2).fetch(:decisions).first
    edges = decision.fetch(:edge_table)
    by_source = edges.group_by { |edge| edge.fetch(:from) }

    assert_equal "atom1", by_source.fetch("atom0").find { |edge| edge.fetch(:truth) == true }.fetch(:destination)
    # rubocop:disable Lint/BooleanSymbol -- graph destinations use serialized enum labels
    assert_equal :true, by_source.fetch("atom0").find { |edge| edge.fetch(:truth) == false }.fetch(:destination)
    assert_equal :true, by_source.fetch("atom1").find { |edge| edge.fetch(:truth) == false }.fetch(:destination)
    assert_equal :false, by_source.fetch("atom1").find { |edge| edge.fetch(:truth) == true }.fetch(:destination)
    # rubocop:enable Lint/BooleanSymbol
  end

  def test_evidence_replays_not_tree_and_rejects_wrong_outcome
    tree = not_tree(atom(0))
    inventory = inventory_for(tree, 1)
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "run")

    accepted = evidence.record(execution: { run_id: "run", execution_id: "ok", decision_id: "d", test_id: nil,
                                            phase: "body", owner: {}, observations: [[0, true]], outcome: false,
                                            status: "completed" })
    rejected = evidence.record(execution: { run_id: "run", execution_id: "bad", decision_id: "d", test_id: nil,
                                            phase: "body", owner: {}, observations: [[0, true]], outcome: true,
                                            status: "completed" })

    assert_equal "recorded", accepted.fetch(:status)
    assert_equal "rejected", rejected.fetch(:status)
    assert_equal([[true]], evidence.snapshot.fetch(:vectors).map { |vector| vector.fetch(:values) })
  end

  def flow_decision(kind: "multiway", count: 3)
    { id: "flow", kind: kind, tree: nil, conditions: [],
      alternatives: (0...count).map { |index| { id: "a#{index}", index: index, expression: "alt#{index}" } } }
  end

  def test_analyzer_reports_alternative_coverage_without_boolean_ladders
    decision = flow_decision
    vectors = [
      { id: "first", decision_id: "flow", values: [true, nil, nil], outcome: true,
        test_ids: ["t1"] },
      { id: "second", decision_id: "flow", values: [false, true, nil], outcome: true,
        test_ids: ["t2"] },
      { id: "third", decision_id: "flow", values: [false, false, true], outcome: true,
        test_ids: ["t3"] }
    ]

    result = Branchproof::Analyzer.new(inventory: { decisions: [decision] }, evidence: { vectors: vectors }, limits: {}).call
    analyzed = result.fetch(:decisions).first

    assert_empty analyzed.fetch(:condition_results)
    assert_equal "covered", analyzed.dig(:coverage, :alternative, :status)
    assert_equal [3, 3], [analyzed.dig(:coverage, :alternative, :covered_alternatives),
                          analyzed.dig(:coverage, :alternative, :required_alternatives)]
    assert_equal "not_applicable", analyzed.dig(:coverage, :mcdc, :status)
    assert_equal [0, 0], [result.dig(:coverage, :condition, :condition_count),
                          result.dig(:coverage, :mcdc, :supported_conditions)]
    assert_equal [3, 3], [result.dig(:coverage, :alternative, :covered_alternatives),
                          result.dig(:coverage, :alternative, :required_alternatives)]
  end

  def test_evidence_accepts_implicit_and_multiway_alternative_traces
    implicit = flow_decision(kind: "implicit", count: 2)
    evidence = Branchproof::Evidence.new(inventory: { decisions: [implicit] }, limits: {}, run_id: "run")
    accepted = evidence.record(execution: { run_id: "run", execution_id: "implicit", decision_id: "flow", test_id: nil,
                                            phase: "body", owner: {}, observations: [[0, true], [1, false]],
                                            outcome: true, status: "completed" })
    assert_equal "recorded", accepted.fetch(:status)
    assert_equal [true, false], evidence.snapshot.fetch(:vectors).first.fetch(:values)

    multiway = flow_decision
    evidence = Branchproof::Evidence.new(inventory: { decisions: [multiway] }, limits: {}, run_id: "run")
    accepted = evidence.record(execution: { run_id: "run", execution_id: "multiway", decision_id: "flow", test_id: nil,
                                            phase: "body", owner: {}, observations: [[0, false], [1, true]],
                                            outcome: true, status: "completed" })
    rejected = evidence.record(execution: { run_id: "run", execution_id: "bad", decision_id: "flow", test_id: nil,
                                            phase: "body", owner: {}, observations: [[0, true], [1, false]],
                                            outcome: true, status: "completed" })
    assert_equal "recorded", accepted.fetch(:status)
    assert_equal "rejected", rejected.fetch(:status)
    assert_equal [false, true, nil], evidence.snapshot.fetch(:vectors).first.fetch(:values)
  end

  def test_evidence_snapshot_merges_nonboolean_shapes_and_vectors
    decision = flow_decision
    source = Branchproof::Evidence.new(inventory: { decisions: [decision] }, limits: {}, run_id: "source")
    source.record(execution: { run_id: "source", execution_id: "e", decision_id: "flow", test_id: nil,
                               phase: "body", owner: {}, observations: [[0, false], [1, false], [2, true]],
                               outcome: true, status: "completed" })
    target = Branchproof::Evidence.new(inventory: { decisions: [decision] }, limits: {}, run_id: "target")

    assert_equal "merged", target.merge(snapshot: source.snapshot).fetch(:status)
    assert_equal 1, target.snapshot.fetch(:vectors).length
    assert_equal "flow", target.snapshot.fetch(:vectors).first.fetch(:decision_id)
  end

  def test_unexecuted_flow_decision_reports_each_missing_alternative
    decision = flow_decision
    analyzed = Branchproof::Analyzer.new(inventory: { decisions: [decision] }, evidence: { vectors: [] }, limits: {}).call
                                    .fetch(:decisions).first

    coverage = analyzed.fetch(:coverage).fetch(:alternative)
    assert_equal "unexecuted", coverage.fetch(:status)
    assert_equal %w[a0 a1 a2], coverage.fetch(:missing_alternatives)
    assert_equal [true, true], [analyzed.fetch(:condition_results).empty?, analyzed.fetch(:conditions).empty?]
  end

  def test_nonboolean_public_mcdc_helpers_are_inapplicable
    decision = flow_decision
    analyzer = Branchproof::Analyzer.new(inventory: { decisions: [decision] }, evidence: { vectors: [] }, limits: {})

    refute analyzer.pair?(decision_id: "flow", condition_index: 0,
                          left: { decision_id: "flow", values: [true, nil, nil], outcome: true },
                          right: { decision_id: "flow", values: [false, true, nil], outcome: true })
    assert_nil analyzer.missing(decision_id: "flow", condition_index: 0)
  end

  def test_evidence_rejects_malformed_nonboolean_trace_and_preserves_state
    decision = flow_decision
    evidence = Branchproof::Evidence.new(inventory: { decisions: [decision] }, limits: {}, run_id: "run")
    result = evidence.record(execution: { run_id: "run", execution_id: "bad", decision_id: "flow", test_id: nil,
                                          phase: "body", owner: {}, observations: [[0, true], [2, false]],
                                          outcome: true, status: "completed" })

    assert_equal "rejected", result.fetch(:status)
    assert_empty evidence.snapshot.fetch(:vectors)
  end

  def test_flow_snapshot_merge_rejects_malformed_vector_atomically
    decision = flow_decision
    source = Branchproof::Evidence.new(inventory: { decisions: [decision] }, limits: {}, run_id: "source")
    source.record(execution: { run_id: "source", execution_id: "e", decision_id: "flow", test_id: nil,
                               phase: "body", owner: {}, observations: [[0, false], [1, false], [2, true]],
                               outcome: true, status: "completed" })
    snapshot = source.snapshot
    malformed = snapshot[:vectors].first.merge(values: [true, nil, nil])
    target = Branchproof::Evidence.new(inventory: { decisions: [decision] }, limits: {}, run_id: "target")

    assert_equal "rejected", target.merge(snapshot: snapshot.merge(vectors: [malformed])).fetch(:status)
    assert_empty target.snapshot.fetch(:vectors)
  end
end
