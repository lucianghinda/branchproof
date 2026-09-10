# frozen_string_literal: true

require "test_helper"
require "branchproof/analyzer"
require "branchproof/minimizer"
require_relative "support/boolean_oracle"

class TestAnalysisAcceptance < Minitest::Test
  def test_edge_graph_replay_matches_effective_masks_and_independent_oracle_for_all_16312_traces
    trace_count = 0
    (1..6).each do |leaf_count|
      trees(leaf_count).each do |tree|
        vectors = unique_vectors(tree, leaf_count)
        analysis = analyze(tree, vectors, { constraint_search_states: 1 }).fetch(:decisions).first
        vectors.each do |vector|
          expected = oracle_masks(tree, vector)
          replayed = replay_edges(analysis.fetch(:edge_table), vector)
          assert_equal vector.fetch(:outcome), replayed.fetch(:outcome),
                       "terminal tree=#{tree.inspect} vector=#{vector.inspect}"
          assert_equal expected, replayed.fetch(:mask), "edge replay tree=#{tree.inspect} vector=#{vector.inspect}"
          assert_equal expected, analysis.fetch(:effective_masks_by_vector).fetch(vector.fetch(:id)),
                       "analyzer mask tree=#{tree.inspect} vector=#{vector.inspect}"
          trace_count += 1
        end
      end
    end
    assert_equal 16_312, trace_count
  end

  def test_corrupt_aborted_and_mismatched_vectors_make_analysis_incomplete_with_diagnostics
    tree = and_tree
    vectors = [
      { id: "aborted", decision_id: "d", status: "aborted", values: [false, nil], outcome: false },
      { id: "corrupt", decision_id: "d", status: "completed", values: [false, true], outcome: true }
    ]
    result = analyze(tree, vectors)

    refute result.dig(:completeness, :analysis)
    assert_equal %w[incomplete_vector invalid_vector], result.fetch(:diagnostics).map { |item|
      item.fetch(:code)
    }.uniq.sort
    assert_empty result.fetch(:decisions).first.fetch(:effective_masks_by_vector)
    mismatch = analyze(tree,
                       [{ id: "mismatch", decision_id: "d", source_id: "other-source", status: "completed", values: [false, nil],
                          outcome: false }])
    assert_includes mismatch.fetch(:diagnostics).map { |item| item.fetch(:code) }, "invalid_vector"
  end

  def test_constraint_limit_marks_top_level_analysis_incomplete
    tree = { type: :and, left: and_tree, right: atom(2) }
    result = analyze(tree, [{ id: "v", decision_id: "d", values: [false, nil, nil], outcome: false }],
                     { constraint_search_states: 1 })

    refute result.dig(:completeness, :analysis)
    assert(result.fetch(:diagnostics).any? do |item|
      %w[limit_reached incomplete_analysis].include?(item.fetch(:code))
    end)
  end

  def test_candidate_pair_is_accepted_only_when_target_changes_and_is_effective
    analyzer = Branchproof::Analyzer.new(inventory: inventory_for(and_tree), evidence: { vectors: [] }, limits: {})
    left = { id: "left", decision_id: "d", values: [false, nil], outcome: false }
    right = { id: "right", decision_id: "d", values: [true, true], outcome: true }

    assert analyzer.pair?(decision_id: "d", condition_index: 0, left: left, right: right)
    refute analyzer.pair?(decision_id: "d", condition_index: 0, left: left,
                          right: { id: "same", decision_id: "d", values: [true, nil], outcome: false })
  end

  def test_literal_truth_constraints_do_not_leak_between_decisions
    first = { id: "first", tree: and_tree,
              conditions: [{ id: "first-0", index: 0, literal_truth: true }, { id: "first-1", index: 1 }] }
    second = { id: "second", tree: and_tree,
               conditions: [{ id: "second-0", index: 0, literal_truth: false }, { id: "second-1", index: 1 }] }
    inventory = { decisions: [first, second] }
    evidence = { vectors: [{ id: "f", decision_id: "first", values: [true, false], outcome: false },
                           { id: "s", decision_id: "second", values: [false, nil], outcome: false }] }
    result = Branchproof::Analyzer.new(inventory: inventory, evidence: evidence, limits: {}).call

    assert_equal(%w[first second], result.fetch(:decisions).map { |item| item.fetch(:decision_id) })
    first_result = result.fetch(:decisions).find { |item| item.fetch(:decision_id) == "first" }
    second_result = result.fetch(:decisions).find { |item| item.fetch(:decision_id) == "second" }
    refute_equal(first_result.fetch(:condition_results).map do |item|
      item.fetch(:constraint_result)
    end, second_result.fetch(:condition_results).map do |item|
           item.fetch(:constraint_result)
         end)
  end

  def test_repeated_analysis_is_stable_including_diagnostic_counts
    vectors = [{ id: "bad", decision_id: "d", values: [false, true], outcome: true }]
    analyzer = Branchproof::Analyzer.new(inventory: inventory_for(and_tree), evidence: { vectors: vectors }, limits: {})
    first = analyzer.call
    second = analyzer.call

    assert_equal first, second
    assert_equal first.fetch(:diagnostics).length, second.fetch(:diagnostics).length
  end

  def test_test_minimization_matches_bruteforce_for_all_343_owner_configurations
    base_vectors = [
      { id: "v1", decision_id: "d", values: [false, nil], outcome: false },
      { id: "v2", decision_id: "d", values: [true, false], outcome: false },
      { id: "v3", decision_id: "d", values: [true, true], outcome: true }
    ]
    owner_sets = (1..7).map { |bits| (0...3).filter_map { |index| "t#{index + 1}" if bits.anybits?(1 << index) } }
    configurations = owner_sets.repeated_permutation(3).to_a
    configurations.each do |owners|
      vectors = base_vectors.each_with_index.map { |vector, index| vector.merge(test_ids: owners[index]) }
      analysis = analyze(and_tree, vectors)
      actual = begin
        Branchproof::Minimizer.new(analysis: analysis, evidence: { vectors: vectors }, limits: {}).call(objective: :tests,
                                                                                                        decision_ids: ["d"])
      rescue StandardError => e
        flunk "minimizer raised for #{owners.inspect}: #{e.class}: #{e.message}"
      end
      expected = brute_force_test_cover(vectors, analysis)
      assert_equal "EXACT_MINIMUM", actual.fetch(:status), owners.inspect
      assert_equal expected, actual.fetch(:selected_ids), owners.inspect
    end
    assert_equal 343, configurations.length
  end

  private

  def atom(index)
    { type: :atom, index: index }
  end

  def trees(leaves)
    return [atom(0)] if leaves == 1

    (1...leaves).flat_map do |left_count|
      trees(left_count).product(trees(leaves - left_count)).flat_map do |left, right|
        shifted = offset(right, left_count)
        %i[and or].map { |type| { type: type, left: left, right: shifted } }
      end
    end
  end

  def offset(tree, amount)
    return atom(tree.fetch(:index) + amount) if tree.fetch(:type) == :atom

    { type: tree.fetch(:type), left: offset(tree.fetch(:left), amount), right: offset(tree.fetch(:right), amount) }
  end

  def all_assignments(count)
    (0...(1 << count)).map { |bits| (0...count).map { |index| (bits >> index).allbits?(1) } }
  end

  def unique_vectors(tree, count)
    seen = Set.new
    all_assignments(count).filter_map do |assignment|
      outcome, trace = BooleanOracle.evaluate(tree, assignment)
      key = [trace, outcome]
      next unless seen.add?(key)

      values = Array.new(count)
      trace.each { |index, value| values[index] = value }
      { id: "v-#{trace.hash}-#{outcome}", decision_id: "d", values: values, outcome: outcome }
    end
  end

  def oracle_masks(tree, vector)
    values = vector.fetch(:values)
    trace = values.each_index.filter_map { |index| [index, values[index]] unless values[index].nil? }
    mask = 0
    completions = all_assignments(values.length).filter_map do |assignment|
      result, candidate_trace = BooleanOracle.evaluate(tree, assignment)
      assignment if candidate_trace == trace && result == vector.fetch(:outcome)
    end
    raise "oracle trace mismatch" if completions.empty?

    trace.map(&:first).each do |target|
      effective = completions.any? do |assignment|
        flipped = assignment.dup
        flipped[target] = !flipped[target]
        flipped_result, = BooleanOracle.evaluate(tree, flipped)
        flipped_result != vector.fetch(:outcome)
      end
      mask |= 1 << target if effective
    end
    mask
  end

  def replay_edges(edges, vector)
    by_source = edges.group_by { |edge| edge.fetch(:from) }
    current = "atom0"
    mask = 0
    loop do
      value = vector.fetch(:values)[current.delete_prefix("atom").to_i]
      edge = by_source.fetch(current).find { |candidate| candidate.fetch(:truth) == value }
      mask = (mask & ~edge.fetch(:clear_mask)) | (1 << edge.fetch(:index))
      destination = edge.fetch(:destination)
      if destination.is_a?(Symbol) && %w[true false].include?(destination.to_s)
        return { outcome: destination.to_s == "true", mask: mask }
      end

      current = destination
    end
  end

  def and_tree
    { type: :and, left: atom(0), right: atom(1) }
  end

  def inventory_for(tree)
    conditions = tree_leaves(tree).map { |index| { id: "c#{index}", index: index } }
    { decisions: [{ id: "d", source_id: "source", tree: tree, conditions: conditions }] }
  end

  def tree_leaves(tree)
    tree.fetch(:type) == :atom ? [tree.fetch(:index)] : tree_leaves(tree.fetch(:left)) + tree_leaves(tree.fetch(:right))
  end

  def analyze(tree, vectors, limits = {})
    Branchproof::Analyzer.new(inventory: inventory_for(tree), evidence: { vectors: vectors }, limits: limits).call
  end

  def brute_force_test_cover(vectors, analysis)
    target = Set[["d", 0, false], ["d", 0, true], ["d", 1, false], ["d", 1, true]]
    masks = analysis.fetch(:decisions).first.fetch(:effective_masks_by_vector)
    candidates = vectors.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |vector, result|
      mask = masks.fetch(vector.fetch(:id))
      (0...vector.fetch(:values).length).each do |index|
        next unless mask.anybits?(1 << index)

        vector.fetch(:test_ids).each do |test_id|
          result[test_id].add(["d", index, vector.fetch(:values)[index]])
        end
      end
    end
    ids = candidates.keys.sort
    (0..ids.length).each do |size|
      found = ids.combination(size).find do |subset|
        subset.flat_map do |id|
          candidates.fetch(id).to_a
        end.to_set >= target
      end
      return found if found
    end
    []
  end
end
