# frozen_string_literal: true

require "test_helper"

class TestDecisionTableEquivalence < Minitest::Test
  DT = Branchproof::DecisionTable

  def atom(index) = { type: :atom, index: index }
  def and_node(left, right) = { type: :and, left: left, right: right }
  def or_node(left, right) = { type: :or, left: left, right: right }
  def not_node(child) = { type: :not, child: child }

  def decision(tree, count)
    { id: "equivalence", tree: tree,
      conditions: (0...count).map { |index| { id: "c#{index}", index: index } } }
  end

  def evaluate(node, assignment, values)
    case node[:type].to_s
    when "atom"
      index = node[:index]
      values[index] = assignment[index]
      assignment[index]
    when "not" then !evaluate(node[:child], assignment, values)
    when "and" then evaluate(node[:left], assignment, values) && evaluate(node[:right], assignment, values)
    when "or" then evaluate(node[:left], assignment, values) || evaluate(node[:right], assignment, values)
    end
  end

  def traces(count, tree)
    items = (0...(1 << count)).map do |mask|
      assignment = (0...count).to_h { |index| [index, mask.anybits?(1 << index)] }
      values = Array.new(count)
      outcome = evaluate(tree, assignment, values)
      { id: "v#{mask}", values: values, outcome: outcome, test_ids: ["t#{mask}"] }
    end
    items.uniq { |vector| [vector[:values], vector[:outcome]] }
  end

  def test_indexed_overlay_matches_reference_matcher_for_generated_traces
    tree = and_node(or_node(atom(0), not_node(atom(1))),
                    or_node(and_node(atom(2), atom(3)), atom(4)))
    decision = decision(tree, 5)
    vectors = traces(5, tree)
    result = DT.build(decision: decision, vectors: vectors, limits: {})

    result[:rules].each do |rule|
      expected = vectors.select { |vector| DT.matches?(rule, vector) }
      assert_equal expected.map { |vector| vector[:id] }.sort, rule[:vector_ids]
      assert_equal expected.empty? ? "missing" : "covered", rule[:coverage]
    end
  end

  def test_noncanonical_vectors_keep_wildcard_compatibility
    tree = and_node(atom(0), atom(1))
    decision = decision(tree, 2)
    vectors = traces(2, tree) + [
      { id: "extra", values: [false, true, :ignored], outcome: false, test_ids: [] },
      { id: "malformed", values: [false, true], outcome: false, test_ids: [] }
    ]
    result = DT.build(decision: decision, vectors: vectors, limits: {})

    result[:rules].each do |rule|
      expected = vectors.select { |vector| DT.matches?(rule, vector) }
      assert_equal expected.map { |vector| vector[:id] }.sort, rule[:vector_ids]
    end
  end

  def test_valid_generated_vectors_do_not_call_rule_matcher
    tree = and_node(or_node(atom(0), atom(1)), atom(2))
    decision = decision(tree, 3)
    vectors = traces(3, tree)
    original = DT.method(:matches?)
    calls = 0
    DT.define_singleton_method(:matches?) do |rule, vector|
      calls += 1
      original.call(rule, vector)
    end

    DT.build(decision: decision, vectors: vectors, limits: {})
    assert_equal 0, calls
  ensure
    DT.define_singleton_method(:matches?, original) if original
  end

  def test_public_overlay_preserves_overlapping_and_nonconsecutive_rules
    rules = [
      { id: "wild", index: 7, label: "wild", conditions: %w[false dont_care], outcome: false,
        reachability: "unknown", reachability_reason: nil },
      { id: "specific", index: 3, label: "specific", conditions: %w[false true], outcome: false,
        reachability: "unknown", reachability_reason: nil }
    ]
    vector = { id: "v", values: [false, true], outcome: false, test_ids: [] }
    result = DT.overlay(decision_id: "d", rules: rules, vectors: [vector])

    assert_equal(%w[covered covered], result[:rules].map { |rule| rule[:coverage] })
    assert_equal([%w[v], %w[v]], result[:rules].map { |rule| rule[:vector_ids] })
  end

  def test_two_hundred_seeded_trees_match_independent_ruby_traces
    200.times do |seed|
      random = Random.new(seed)
      count = 2 + random.rand(9)
      tree = random_tree(random, count)
      vectors = traces(count, tree)
      result = DT.build(decision: decision(tree, count), vectors: vectors,
                        limits: { max_conditions_for_decision_table: count })

      result[:rules].each do |rule|
        expected = vectors.select { |vector| DT.matches?(rule, vector) }
        assert_equal expected.map { |vector| vector[:id] }.sort, rule[:vector_ids], "seed=#{seed}"
      end
    end
  end

  def random_tree(random, count, depth = 0)
    return atom(random.rand(count)) if depth >= 5 || random.rand(4).zero?

    left = random_tree(random, count, depth + 1)
    right = random_tree(random, count, depth + 1)
    return not_node(left) if random.rand(3).zero?

    random.rand(2).zero? ? and_node(left, right) : or_node(left, right)
  end
end
