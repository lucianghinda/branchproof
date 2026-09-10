# frozen_string_literal: true

require "test_helper"
require "branchproof/analyzer"
require_relative "support/boolean_oracle"

class TestAnalyzer < Minitest::Test
  def atom(index) = { type: :atom, index: index }

  def trees(leaves)
    return [atom(0)] if leaves == 1

    (1...leaves).flat_map do |left_count|
      trees(left_count).product(trees(leaves - left_count)).flat_map do |left, right|
        offset(right, left_count).flat_map do |shifted_right|
          %i[and or].map { |type| { type: type, left: left, right: shifted_right } }
        end
      end
    end
  end

  def offset(tree, amount)
    return [{ type: :atom, index: tree[:index] + amount }] if tree[:type] == :atom

    [{ type: tree[:type], left: offset(tree[:left], amount).first, right: offset(tree[:right], amount).first }]
  end

  def leaves(tree)
    tree[:type] == :atom ? [tree[:index]] : leaves(tree[:left]) + leaves(tree[:right])
  end

  def observed(tree, assignment)
    result, trace = BooleanOracle.evaluate(tree, assignment)
    values = Array.new(leaves(tree).length)
    trace.each { |index, value| values[index] = value }
    { id: "#{assignment.hash}-#{result}", decision_id: "d", values: values, outcome: result }
  end

  def run_analysis(tree, vectors)
    inventory = { decisions: [{ id: "d", tree: tree,
                                conditions: leaves(tree).map { |index| { id: "c#{index}", index: index } } }] }
    Branchproof::Analyzer.new(inventory: inventory, evidence: { vectors: vectors }, limits: {}).call[:decisions].first
  end

  def all_assignments(count)
    (0...(1 << count)).map { |bits| (0...count).map { |index| (bits >> index).odd? } }
  end

  def test_effective_masks_match_independent_oracle_for_every_tree_through_six_leaves
    tree_count = 0
    vector_count = 0
    (1..6).each do |count|
      trees(count).each do |tree|
        assignments = all_assignments(count)
        vectors = assignments.map { |assignment| observed(tree, assignment) }
        analysis = run_analysis(tree, vectors)
        masks = analysis[:effective_masks_by_vector]
        vectors.each do |vector|
          expected = leaves(tree).sum do |target|
            if BooleanOracle.effective?(tree, [vector[:outcome], vector[:values].each_index.filter_map do |index|
              [index, vector[:values][index]] unless vector[:values][index].nil?
            end], target)
              (1 << target)
            else
              0
            end
          end
          assert_equal expected, masks[vector[:id]], "tree=#{tree.inspect} vector=#{vector.inspect}"
        end
        tree_count += 1
        vector_count += vectors.length
      end
    end
    assert_operator tree_count, :>, 100
    assert_operator vector_count, :>, 4000
  end

  def test_structural_validation_rejects_skipped_and_extra_observations
    tree = { type: :and, left: atom(0), right: atom(1) }
    valid = { id: "valid", decision_id: "d", values: [false, nil], outcome: false }
    malformed = { id: "bad", decision_id: "d", values: [false, true], outcome: false }
    result = run_analysis(tree, [valid, malformed])
    assert_equal({ "valid" => 1 }, result[:effective_masks_by_vector])
  end

  def test_pair_predicate_enforces_all_t4_partitions
    tree = { type: :and, left: atom(0), right: atom(1) }
    inventory = { decisions: [{ id: "d", tree: tree, conditions: [{ id: "c0", index: 0 }, { id: "c1", index: 1 }] }] }
    analyzer = Branchproof::Analyzer.new(inventory: inventory, evidence: { vectors: [] }, limits: {})
    valid = lambda { |values, outcome, status: "completed"|
      { id: values.inspect, decision_id: "d", values: values, outcome: outcome, status: status }
    }
    left = valid.call([false, nil], false)
    right = valid.call([true, true], true)
    assert analyzer.pair?(decision_id: "d", condition_index: 0, left: left, right: right)
    refute analyzer.pair?(decision_id: "d", condition_index: 0, left: left, right: valid.call([true, nil], false))
    refute analyzer.pair?(decision_id: "d", condition_index: 0, left: left, right: valid.call([false, nil], false))
    refute analyzer.pair?(decision_id: "d", condition_index: 0, left: left, right: valid.call([true, true], false))
    refute analyzer.pair?(decision_id: "d", condition_index: 0, left: left,
                          right: valid.call([true, true], true, status: "aborted"))
    refute analyzer.pair?(decision_id: "d", condition_index: 0, left: left, right: valid.call([true, false], false))
  end

  def test_c10_accepts_c_when_masked_a_differs
    tree = { type: :and, left: { type: :or, left: atom(0), right: atom(1) }, right: atom(2) }
    vectors = [
      { id: "one", decision_id: "d", values: [true, nil, false], outcome: false },
      { id: "two", decision_id: "d", values: [false, true, true], outcome: true }
    ]
    analysis = run_analysis(tree, vectors)
    assert_equal "PROVEN", analysis[:condition_results][2][:status]
    assert_equal "NOT_PROVEN", analysis[:condition_results][0][:status]
  end

  def test_pair_selection_ignores_lexicographically_first_masked_vector
    tree = { type: :and, left: atom(0), right: atom(1) }
    vectors = [
      { id: "a", decision_id: "d", values: [false, nil], outcome: false },
      { id: "b", decision_id: "d", values: [true, false], outcome: false },
      { id: "c", decision_id: "d", values: [true, true], outcome: true }
    ]
    analysis = run_analysis(tree, vectors)
    assert_equal(2, analysis[:condition_results].count { |result| result[:status] == "PROVEN" })
  end

  def test_edge_table_has_two_continuation_edges_per_atom_for_all_trees_through_six_leaves
    count = 0
    (1..6).each do |leaf_count|
      trees(leaf_count).each do |tree|
        decision = { id: "d", tree: tree, conditions: leaves(tree).map { |index| { id: "c#{index}", index: index } } }
        result = Branchproof::Analyzer.new(inventory: { decisions: [decision] }, evidence: { vectors: [] },
                                           limits: {}).call[:decisions].first
        edges = result[:edge_table]
        assert_equal leaf_count * 2, edges.length
        assert(edges.all? { |edge| edge.key?(:truth) && edge.key?(:destination) && edge.key?(:clear_mask) })
        count += 1
      end
    end
    assert_operator count, :>, 100
  end

  def test_missing_reports_no_observations_literal_barriers_and_limit
    tree = { type: :and, left: atom(0), right: atom(1) }
    decision = { id: "d", tree: tree,
                 conditions: [{ id: "c0", index: 0 }, { id: "c1", index: 1, literal_truth: true }] }
    analyzer = Branchproof::Analyzer.new(inventory: { decisions: [decision] }, evidence: { vectors: [] },
                                         limits: { constraint_search_states: 10 })
    assert_equal "NO_OBSERVATIONS", analyzer.missing(decision_id: "d", condition_index: 0)[:status]

    analyzer = Branchproof::Analyzer.new(
      inventory: { decisions: [decision] },
      evidence: { vectors: [{ id: "v", decision_id: "d", values: [false, nil], outcome: false }] },
      limits: { constraint_search_states: 10 }
    )

    blocked = analyzer.missing(decision_id: "d", condition_index: 1)
    assert_equal "CANDIDATE", blocked[:status]
    false_decision = decision.merge(conditions: [{ id: "c0", index: 0 }, { id: "c1", index: 1, literal_truth: false }])
    false_analyzer = Branchproof::Analyzer.new(
      inventory: { decisions: [false_decision] },
      evidence: { vectors: [{ id: "v", decision_id: "d", values: [true, false], outcome: false }] },
      limits: {}
    )
    assert_equal "INFEASIBLE_IN_MODEL", false_analyzer.missing(decision_id: "d", condition_index: 1)[:status]

    limited = Branchproof::Analyzer.new(
      inventory: { decisions: [decision] },
      evidence: { vectors: [{ id: "v", decision_id: "d", values: [false, nil], outcome: false }] },
      limits: { constraint_search_states: 1 }
    )
    limited.missing(decision_id: "d", condition_index: 0)
    assert_equal "LIMIT_REACHED", limited.missing(decision_id: "d", condition_index: 1)[:status]
  end
end
