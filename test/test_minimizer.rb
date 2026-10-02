# frozen_string_literal: true

require "test_helper"
require "branchproof/analyzer"
require "branchproof/minimizer"

class TestMinimizer < Minitest::Test
  def assert_complete_result(actual, objective:, scope:, target:, selected:, status:, lower_bound:, visited:, reasons:,
                             necessary:, interchangeable:, additional:)
    assert_equal({ objective: objective, scope_decision_ids: scope, target_obligations: target,
                   selected_ids: selected, status: status, lower_bound: lower_bound, visited_nodes: visited,
                   reasons: reasons, necessary_ids: necessary, interchangeable_ids: interchangeable,
                   additional_ids: additional }, actual)
  end

  def analysis
    tree = { type: :and, left: { type: :atom, index: 0 }, right: { type: :atom, index: 1 } }
    inventory = { decisions: [{ id: "d", tree: tree, conditions: [{ id: "c0", index: 0 }, { id: "c1", index: 1 }] }] }
    evidence = { vectors: [
      { id: "v1", decision_id: "d", values: [false, nil], outcome: false, test_ids: ["t1"] },
      { id: "v2", decision_id: "d", values: [true, false], outcome: false, test_ids: ["t1"] },
      { id: "v3", decision_id: "d", values: [true, true], outcome: true, test_ids: ["t1"] }
    ] }
    [Branchproof::Analyzer.new(inventory: inventory, evidence: evidence, limits: {}).call, evidence]
  end

  def test_vector_minimum_is_three_and_test_minimum_is_one
    result, evidence = analysis
    minimizer = Branchproof::Minimizer.new(analysis: result, evidence: evidence, limits: {})
    vectors = minimizer.call(objective: :vectors, decision_ids: ["d"])
    tests = minimizer.call(objective: :tests, decision_ids: ["d"])
    target = [["d", 0, false], ["d", 0, true], ["d", 1, false], ["d", 1, true]]
    assert_complete_result(vectors, objective: :vectors, scope: ["d"], target: target, selected: %w[v1 v2 v3],
                                    status: "EXACT_MINIMUM", lower_bound: 2, visited: 15, reasons: [],
                                    necessary: %w[v1 v2 v3], interchangeable: [], additional: [])
    assert_complete_result(tests, objective: :tests, scope: ["d"], target: target, selected: ["t1"],
                                  status: "EXACT_MINIMUM", lower_bound: 1, visited: 3, reasons: [],
                                  necessary: ["t1"], interchangeable: [], additional: [])
  end

  def test_vector_result_matches_independent_bruteforce_set_cover
    result, evidence = analysis
    candidates = {
      "v1" => Set[["d", 0, false]],
      "v2" => Set[["d", 1, false]],
      "v3" => Set[["d", 0, true], ["d", 1, true]]
    }
    target = candidates.values.reduce(Set.new, :|)
    covers = (0..3).each_with_object([]) do |size, all|
      all.concat(candidates.keys.combination(size).select do |ids|
        ids.flat_map do |id|
          candidates[id].to_a
        end.to_set >= target
      end)
    end
    expected = covers.min_by { |ids| [ids.length, ids] }
    actual = Branchproof::Minimizer.new(analysis: result, evidence: evidence, limits: {}).call(objective: :vectors,
                                                                                               decision_ids: ["d"])
    assert_equal expected, actual[:selected_ids]
  end

  def test_project_scope_is_one_combined_cover_and_bruteforce_canonical
    result, evidence = analysis
    tree = { type: :and, left: { type: :atom, index: 0 }, right: { type: :atom, index: 1 } }
    second_evidence = { vectors: [
      { id: "v4", decision_id: "e", values: [false, nil], outcome: false, test_ids: ["t1"] },
      { id: "v5", decision_id: "e", values: [true, false], outcome: false, test_ids: ["t1"] },
      { id: "v6", decision_id: "e", values: [true, true], outcome: true, test_ids: ["t1"] }
    ] }
    second_inventory = { decisions: [{ id: "e", tree: tree,
                                       conditions: [{ id: "e0", index: 0 }, { id: "e1", index: 1 }] }] }
    second_result = Branchproof::Analyzer.new(inventory: second_inventory, evidence: second_evidence, limits: {}).call
    result = Marshal.load(Marshal.dump(result))
    result[:decisions] << second_result[:decisions].first
    evidence = { vectors: evidence[:vectors] + second_evidence[:vectors] }
    minimum = Branchproof::Minimizer.new(analysis: result, evidence: evidence, limits: {}).call(objective: :tests,
                                                                                                decision_ids: %w[
                                                                                                  d e
                                                                                                ])
    target = %w[d e].flat_map do |decision|
      [[decision, 0, false], [decision, 0, true], [decision, 1, false], [decision, 1, true]]
    end
    assert_complete_result(minimum, objective: :tests, scope: %w[d e], target: target, selected: ["t1"],
                                    status: "EXACT_MINIMUM", lower_bound: 1, visited: 3, reasons: [],
                                    necessary: ["t1"], interchangeable: [], additional: [])
  end

  def test_best_found_remains_a_valid_cover_when_budget_is_exhausted
    result, evidence = analysis
    minimum = Branchproof::Minimizer.new(analysis: result, evidence: evidence, limits: { exact_search_nodes: 1 }).call(
      objective: :vectors, decision_ids: ["d"]
    )
    assert_complete_result(minimum, objective: :vectors, scope: ["d"],
                                    target: [["d", 0, false], ["d", 0, true], ["d", 1, false], ["d", 1, true]],
                                    selected: %w[v1 v2 v3], status: "BEST_FOUND", lower_bound: 2, visited: 1,
                                    reasons: ["exact search budget exhausted"], necessary: %w[v1 v2 v3],
                                    interchangeable: [], additional: [])
  end

  def test_candidate_limit_uses_full_universe_before_best_found_label
    result, evidence = analysis
    minimum = Branchproof::Minimizer.new(analysis: result, evidence: evidence, limits: { exact_candidates: 1 }).call(
      objective: :vectors, decision_ids: ["d"]
    )
    assert_complete_result(minimum, objective: :vectors, scope: ["d"],
                                    target: [["d", 0, false], ["d", 0, true], ["d", 1, false], ["d", 1, true]],
                                    selected: %w[v1 v2 v3], status: "BEST_FOUND", lower_bound: nil, visited: 0,
                                    reasons: ["candidate count exceeds exact search limit"],
                                    necessary: %w[v1 v2 v3], interchangeable: [], additional: [])
  end

  def test_unattributed_essential_obligation_is_unavailable_for_tests
    result, evidence = analysis
    evidence[:vectors][2] = evidence[:vectors][2].dup.tap { |vector| vector.delete(:test_ids) }
    minimum = Branchproof::Minimizer.new(analysis: result, evidence: evidence, limits: {}).call(objective: :tests,
                                                                                                decision_ids: ["d"])
    assert_complete_result(minimum, objective: :tests, scope: ["d"],
                                    target: [["d", 0, false], ["d", 0, true], ["d", 1, false], ["d", 1, true]],
                                    selected: [], status: "NOT_AVAILABLE", lower_bound: nil, visited: 0,
                                    reasons: ['missing ownership: ["d", 0, true], ["d", 1, true]'],
                                    necessary: [], interchangeable: [], additional: [])
  end

  def test_validates_objective_and_vector_scope
    result, evidence = analysis
    minimizer = Branchproof::Minimizer.new(analysis: result, evidence: evidence, limits: {})
    assert_raises(ArgumentError) { minimizer.call(objective: :bad, decision_ids: ["d"]) }
    assert_raises(ArgumentError) { minimizer.call(objective: :vectors, decision_ids: %w[d e]) }
  end

  def test_vector_scope_excludes_vectors_from_other_decisions
    result, evidence = analysis
    evidence[:vectors] << { id: "other", decision_id: "other", values: [true, true], outcome: true }

    minimum = Branchproof::Minimizer.new(analysis: result, evidence: evidence, limits: {}).call(
      objective: :vectors, decision_ids: ["d"]
    )

    refute_includes minimum[:additional_ids], "other"
    refute_includes minimum[:selected_ids], "other"
  end

  def test_necessary_ids_are_based_on_union_without_each_candidate
    result = { decisions: [{ decision_id: "d", conditions: [{ id: "c", index: 0 }],
                             condition_results: [{ condition_id: "c", status: "PROVEN" }] }] }
    evidence = { vectors: [] }
    minimizer = Branchproof::Minimizer.new(analysis: result, evidence: evidence, limits: {})
    candidates = { "shared" => Set[["d", 0, true]], "owner" => Set[["d", 0, false]] }
    minimizer.stub(:vector_candidates, candidates) do
      output = minimizer.call(objective: :vectors, decision_ids: ["d"])
      assert_equal %w[owner shared], output[:necessary_ids].sort
    end
  end

  def test_unproven_signs_do_not_inflate_candidate_coverage
    result = { decisions: [{ decision_id: "d", conditions: [{ id: "c0", index: 0 }, { id: "c1", index: 1 }],
                             condition_results: [{ condition_id: "c0", status: "PROVEN" }],
                             effective_masks_by_vector: { "v" => 3 } }] }
    evidence = { vectors: [{ id: "v", decision_id: "d", values: [true, true] }] }
    output = Branchproof::Minimizer.new(analysis: result, evidence: evidence, limits: {}).call(
      objective: :vectors, decision_ids: ["d"]
    )

    assert_equal([["d", 0, true]], output[:target_obligations].select { |obligation| obligation[2] })
    assert_equal "NOT_AVAILABLE", output[:status]
  end

  def test_greedy_removes_redundant_candidates_after_selection
    result = { decisions: [{ decision_id: "d", conditions: [{ id: "c0", index: 0 }, { id: "c1", index: 1 }],
                             condition_results: [{ condition_id: "c0", status: "PROVEN" },
                                                 { condition_id: "c1", status: "PROVEN" }] }] }
    candidates = {
      "a" => Set[["d", 0, true]],
      "b" => Set[["d", 1, true]],
      "c" => Set[["d", 0, true], ["d", 1, true], ["d", 0, false], ["d", 1, false]]
    }
    minimizer = Branchproof::Minimizer.new(analysis: result, evidence: { vectors: [] }, limits: { exact_candidates: 1 })
    minimizer.stub(:vector_candidates, candidates) do
      output = minimizer.call(objective: :vectors, decision_ids: ["d"])
      assert_equal ["c"], output[:selected_ids]
    end
  end

  def test_interleaved_candidate_ids_keep_canonical_tie_breaking
    result = { decisions: [{ decision_id: "d", conditions: [{ id: "c0", index: 0 }, { id: "c1", index: 1 }],
                             condition_results: [{ condition_id: "c0", status: "PROVEN" },
                                                 { condition_id: "c1", status: "PROVEN" }] }] }
    candidates = {
      "z" => Set[["d", 1, true], ["d", 1, false]],
      "b" => Set[["d", 0, false], ["d", 1, true]],
      "y" => Set[["d", 0, true], ["d", 1, false]],
      "a" => Set[["d", 0, true], ["d", 0, false]]
    }
    cases = [
      [{}, "EXACT_MINIMUM", 2, 21, []],
      [{ exact_candidates: 1 }, "BEST_FOUND", nil, 0, ["candidate count exceeds exact search limit"]]
    ]
    cases.each do |limits, status, lower_bound, visited, reasons|
      minimizer = Branchproof::Minimizer.new(analysis: result, evidence: { vectors: [] }, limits: limits)
      minimizer.stub(:vector_candidates, candidates) do
        output = minimizer.call(objective: :vectors, decision_ids: ["d"])
        assert_complete_result(output, objective: :vectors, scope: ["d"],
                                       target: [["d", 0, false], ["d", 0, true], ["d", 1, false], ["d", 1, true]],
                                       selected: %w[a z], status: status, lower_bound: lower_bound, visited: visited,
                                       reasons: reasons, necessary: [], interchangeable: %w[z b y a], additional: %w[b y])
      end
    end
  end

  def test_empty_target_has_a_complete_exact_result
    result = { decisions: [{ decision_id: "d", conditions: [{ id: "c", index: 0 }], condition_results: [] }] }
    output = Branchproof::Minimizer.new(analysis: result, evidence: { vectors: [] }, limits: {}).call(
      objective: :vectors, decision_ids: ["d"]
    )

    assert_complete_result(output, objective: :vectors, scope: ["d"], target: [], selected: [],
                                   status: "EXACT_MINIMUM", lower_bound: nil, visited: 0, reasons: [],
                                   necessary: [], interchangeable: [], additional: [])
  end

  def test_string_key_inputs_and_mutations_between_calls_remain_visible
    decision = { "decision_id" => "d", "conditions" => [{ "id" => "c", "index" => 0 }],
                 "condition_results" => [{ "condition_id" => "c", "status" => "PROVEN" }],
                 "effective_masks_by_vector" => { "v1" => 1, "v2" => 1 } }
    evidence = { "vectors" => [{ "id" => "v1", "decision_id" => "d", "values" => [false] }] }
    minimizer = Branchproof::Minimizer.new(analysis: { "decisions" => [decision] }, evidence: evidence, limits: {})
    unavailable = minimizer.call(objective: :vectors, decision_ids: ["d"])
    assert_complete_result(unavailable, objective: :vectors, scope: ["d"],
                                        target: [["d", 0, false], ["d", 0, true]], selected: [],
                                        status: "NOT_AVAILABLE", lower_bound: nil, visited: 0,
                                        reasons: ['missing ownership: ["d", 0, true]'],
                                        necessary: [], interchangeable: [], additional: [])

    evidence["vectors"] << { "id" => "v2", "decision_id" => "d", "values" => [true] }
    available = minimizer.call(objective: :vectors, decision_ids: ["d"])
    assert_complete_result(available, objective: :vectors, scope: ["d"],
                                      target: [["d", 0, false], ["d", 0, true]], selected: %w[v1 v2],
                                      status: "EXACT_MINIMUM", lower_bound: 2, visited: 7, reasons: [],
                                      necessary: %w[v1 v2], interchangeable: [], additional: [])
  end
end
