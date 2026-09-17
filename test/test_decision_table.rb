# frozen_string_literal: true

require "test_helper"
require "branchproof/analyzer"

class TestDecisionTable < Minitest::Test
  SIGNS = { "true" => "T", "false" => "F", "dont_care" => "-" }.freeze

  def atom(index) = { type: :atom, index: index }
  def and_node(left, right) = { type: :and, left: left, right: right }
  def or_node(left, right) = { type: :or, left: left, right: right }
  def not_node(child) = { type: :not, child: child }

  def decision(tree, count, conditions: nil, **extra)
    conditions ||= (0...count).map { |index| { id: "c#{index}", index: index, expression: "c#{index}" } }
    { id: "d", source_id: "s", tree: tree, conditions: conditions }.merge(extra)
  end

  def table(tree, count, vectors: [], limits: {}, **extra)
    Branchproof::DecisionTable.build(decision: decision(tree, count, **extra), vectors: vectors, limits: limits)
  end

  def signatures(result)
    result[:rules].map do |rule|
      "#{rule[:label]} #{rule[:conditions].map { |value| SIGNS.fetch(value) }.join} => #{rule[:outcome] ? "T" : "F"}"
    end
  end

  def test_conjunction_reflects_ruby_short_circuiting
    assert_equal ["R1 F- => F", "R2 TF => F", "R3 TT => T"],
                 signatures(table(and_node(atom(0), atom(1)), 2))
  end

  def test_disjunction_reflects_ruby_short_circuiting
    assert_equal ["R1 T- => T", "R2 FT => T", "R3 FF => F"],
                 signatures(table(or_node(atom(0), atom(1)), 2))
  end

  def test_nested_logic_is_reduced_structurally
    result = table(and_node(atom(0), or_node(atom(1), atom(2))), 3)

    assert_equal ["R1 F-- => F", "R2 TT- => T", "R3 TFT => T", "R4 TFF => F"], signatures(result)
  end

  def test_negation_keeps_the_underlying_conditions
    result = table(and_node(not_node(atom(0)), atom(1)), 2)

    assert_equal ["R1 T- => F", "R2 FF => F", "R3 FT => T"], signatures(result)
  end

  def test_single_atom_produces_both_outcomes
    assert_equal ["R1 F => F", "R2 T => T"], signatures(table(atom(0), 1))
  end

  def test_dont_care_is_an_explicit_enum_value_not_null
    values = table(and_node(atom(0), atom(1)), 2)[:rules].flat_map { |rule| rule[:conditions] }

    assert_includes values, "dont_care"
    refute_includes values, nil
    assert(values.all? { |value| Branchproof::DecisionTable::CONDITION_VALUES.include?(value) })
  end

  def test_rule_identity_is_stable_and_independent_of_observations
    tree = and_node(atom(0), or_node(atom(1), atom(2)))
    vectors = [{ id: "v", decision_id: "d", values: [false, nil, nil], outcome: false, test_ids: %w[t] }]
    bare = table(tree, 3)[:rules].map { |rule| rule[:id] }
    observed = table(tree, 3, vectors: vectors)[:rules].map { |rule| rule[:id] }

    assert_equal bare, observed
    assert_equal bare.uniq, bare
    assert_equal(bare, table(tree, 3)[:rules].map { |rule| rule[:id] })
  end

  def test_rule_identity_changes_with_the_decision_and_the_outcome
    tree = and_node(atom(0), atom(1))
    other = Branchproof::DecisionTable.build(decision: decision(tree, 2).merge(id: "other"), vectors: [], limits: {})

    refute_equal table(tree, 2)[:rules].first[:id], other[:rules].first[:id]
    assert_equal Branchproof::DecisionTable.rule_id("d", %w[true true], true),
                 table(tree, 2)[:rules].last[:id]
    refute_equal Branchproof::DecisionTable.rule_id("d", %w[true true], true),
                 Branchproof::DecisionTable.rule_id("d", %w[true true], false)
  end

  def test_runtime_overlay_maps_observations_to_rules_and_keeps_owners
    vectors = [
      { id: "v1", decision_id: "d", values: [false, nil, nil], outcome: false, test_ids: %w[free] },
      { id: "v2", decision_id: "d", values: [true, true, nil], outcome: true, test_ids: %w[admin] },
      { id: "v3", decision_id: "d", values: [true, false, false], outcome: false, test_ids: %w[denied] }
    ]
    result = table(and_node(atom(0), or_node(atom(1), atom(2))), 3, vectors: vectors)

    assert_equal(%w[covered covered missing covered], result[:rules].map { |rule| rule[:coverage] })
    assert_equal([%w[free], %w[admin], [], %w[denied]], result[:rules].map { |rule| rule[:tests] })
    assert_equal 3, result[:covered_rules]
    assert_equal 4, result[:required_rules]
    assert_in_delta 75.0, result[:percentage]
    assert_equal "partial", result[:coverage_status]
  end

  def test_short_circuited_observations_never_match_a_required_position
    # [F--] must not satisfy a rule that requires the second condition.
    vectors = [{ id: "v", decision_id: "d", values: [false, nil], outcome: false, test_ids: [] }]
    result = table(and_node(atom(0), atom(1)), 2, vectors: vectors)

    assert_equal(%w[covered missing missing], result[:rules].map { |rule| rule[:coverage] })
  end

  def test_outcome_must_match_before_a_rule_counts_as_covered
    vectors = [{ id: "v", decision_id: "d", values: [true, true], outcome: false, test_ids: [] }]
    result = table(and_node(atom(0), atom(1)), 2, vectors: vectors)

    assert_equal(%w[missing missing missing], result[:rules].map { |rule| rule[:coverage] })
  end

  def test_unattributed_observations_still_cover_a_rule
    vectors = [{ id: "v", decision_id: "d", values: [false, nil], outcome: false, test_ids: [],
                 unattributed_count: 2 }]
    rule = table(and_node(atom(0), atom(1)), 2, vectors: vectors)[:rules].first

    assert_equal "covered", rule[:coverage]
    assert_empty rule[:tests]
    assert_equal 2, rule[:unattributed_count]
  end

  def numeric(subject, operator, value)
    { subject: { kind: "local", name: subject }, operator: operator,
      literal: { type: "integer", value: value } }
  end

  def test_statically_impossible_rules_carry_a_reason_and_leave_the_denominator
    conditions = [{ id: "c0", index: 0, expression: "age > 10", constraint: numeric("age", ">", 10), constraint_safe: true },
                  { id: "c1", index: 1, expression: "age < 5", constraint: numeric("age", "<", 5), constraint_safe: true }]
    result = table(and_node(atom(0), atom(1)), 2, conditions: conditions)
    impossible = result[:rules].last

    assert_equal "statically_impossible", impossible[:reachability]
    assert_equal "conflicting_numeric_bounds", impossible[:reachability_reason]
    assert_equal "excluded", impossible[:coverage]
    assert_equal 3, result[:generated_rules]
    assert_equal 1, result[:impossible_rules]
    assert_equal 2, result[:required_rules]
  end

  def test_unsupported_constraint_shapes_stay_unknown
    conditions = [{ id: "c0", index: 0, expression: "user.age > 10" },
                  { id: "c1", index: 1, expression: "user.age < 5" }]
    result = table(and_node(atom(0), atom(1)), 2, conditions: conditions)

    assert_equal(%w[unknown unknown unknown], result[:rules].map { |rule| rule[:reachability] })
    assert_equal 0, result[:impossible_rules]
  end

  def test_literal_conditions_make_the_contradicting_rule_impossible
    conditions = [{ id: "c0", index: 0, expression: "true", literal_truth: true },
                  { id: "c1", index: 1, expression: "admin?" }]
    result = table(and_node(atom(0), atom(1)), 2, conditions: conditions)

    assert_equal "statically_impossible", result[:rules].first[:reachability]
    assert_equal "boolean_literal_conflict", result[:rules].first[:reachability_reason]
  end

  def test_runtime_evidence_withdraws_a_static_impossibility_claim
    conditions = [{ id: "c0", index: 0, expression: "n > 10", constraint: numeric("n", ">", 10), constraint_safe: true },
                  { id: "c1", index: 1, expression: "n < 5", constraint: numeric("n", "<", 5), constraint_safe: true }]
    vectors = [{ id: "v", decision_id: "d", values: [true, true], outcome: true, test_ids: %w[t] }]
    result = table(and_node(atom(0), atom(1)), 2, conditions: conditions, vectors: vectors)
    rule = result[:rules].last

    assert_equal "observed", rule[:reachability]
    assert_equal "covered", rule[:coverage]
    assert rule[:impossible_withdrawn]
    assert_equal "conflicting_numeric_bounds", rule[:withdrawn_reason]
    assert_nil rule[:reachability_reason]
    assert_equal 0, result[:impossible_rules]
    assert_equal 3, result[:required_rules]
    assert_equal(["constraint_model_conflict"], result[:diagnostics].map { |item| item[:code] })
  end

  def test_condition_limit_prevents_combinatorial_explosion
    tree = (1...6).inject(atom(0)) { |node, index| and_node(node, atom(index)) }
    result = table(tree, 6, limits: { max_conditions_for_decision_table: 5 })

    assert_equal "not_calculated", result[:status]
    assert_equal "decision_table_condition_limit_exceeded", result[:reason]
    assert_empty result[:rules]
    refute result[:reachability_analyzed]
  end

  def test_rule_limit_prevents_combinatorial_explosion
    tree = or_node(and_node(atom(0), atom(1)), and_node(atom(2), atom(3)))
    result = table(tree, 4, limits: { decision_table_rules_per_decision: 2 })

    assert_equal "not_calculated", result[:status]
    assert_equal "decision_table_rule_limit_exceeded", result[:reason]
  end

  def test_rule_budget_is_exact_for_single_atom
    result = table(atom(0), 1, limits: { decision_table_rules_per_decision: 1 })

    assert_equal "not_calculated", result[:status]
    assert_equal "decision_table_rule_limit_exceeded", result[:reason]
    assert_empty result[:rules]
  end

  def test_rule_budget_is_exact_for_two_rule_conjunction
    result = table(and_node(atom(0), atom(1)), 2, limits: { decision_table_rules_per_decision: 2 })

    assert_equal "not_calculated", result[:status]
    assert_equal "decision_table_rule_limit_exceeded", result[:reason]
    assert_empty result[:rules]
  end

  def test_reachability_can_be_disabled_without_exclusions
    conditions = [{ id: "c0", index: 0, expression: "true", literal_truth: true },
                  { id: "c1", index: 1, expression: "false", literal_truth: false }]
    result = Branchproof::DecisionTable.build(
      decision: decision(and_node(atom(0), atom(1)), 2, conditions: conditions),
      vectors: [], limits: {}, reachability: false
    )

    assert_equal 0, result[:impossible_rules]
    assert_equal 3, result[:required_rules]
    reachability = result[:rules].map { |rule| rule[:reachability] }
    assert_equal %w[unknown unknown unknown], reachability
    refute result[:reachability_analyzed]
  end

  def test_unsupported_decisions_are_not_calculated
    result = table(and_node(atom(0), atom(1)), 2, support_status: "UNSUPPORTED")

    assert_equal "not_calculated", result[:status]
    assert_equal "unsupported_decision", result[:reason]
    assert_equal "unsupported", result[:coverage_status]
  end

  def test_missing_tree_is_not_calculated
    result = Branchproof::DecisionTable.build(
      decision: { id: "d", tree: nil, conditions: [] }, vectors: [], limits: {}
    )

    assert_equal "decision_table_unavailable", result[:reason]
  end

  def test_generation_is_deterministic_across_repeated_builds
    tree = or_node(and_node(atom(0), not_node(atom(1))), atom(2))
    first = table(tree, 3)
    second = table(tree, 3)

    assert_equal first[:rules], second[:rules]
  end

  def test_string_keyed_records_are_accepted
    tree = { "type" => "and", "left" => { "type" => "atom", "index" => 0 },
             "right" => { "type" => "atom", "index" => 1 } }
    decision = { "id" => "d", "tree" => tree,
                 "conditions" => [{ "id" => "c0", "index" => 0 }, { "id" => "c1", "index" => 1 }] }
    vectors = [{ "id" => "v", "decision_id" => "d", "values" => [false, nil], "outcome" => false,
                 "test_ids" => ["t"] }]
    result = Branchproof::DecisionTable.build(decision: decision, vectors: vectors, limits: {})

    assert_equal ["R1 F- => F", "R2 TF => F", "R3 TT => T"], signatures(result)
    assert_equal %w[t], result[:rules].first[:tests]
  end

  def test_analyzer_reports_rule_coverage_separately_from_mcdc
    tree = and_node(atom(0), atom(1))
    conditions = [{ id: "c0", index: 0, expression: "age > 10", constraint: numeric("age", ">", 10), constraint_safe: true },
                  { id: "c1", index: 1, expression: "age < 5", constraint: numeric("age", "<", 5), constraint_safe: true }]
    vectors = [{ id: "v1", decision_id: "d", values: [false, nil], outcome: false, test_ids: %w[t] },
               { id: "v2", decision_id: "d", values: [true, false], outcome: false, test_ids: %w[t] }]
    analysis = Branchproof::Analyzer.new(inventory: { decisions: [decision(tree, 2, conditions: conditions)] },
                                         evidence: { vectors: vectors }, limits: {}).call
    decision_analysis = analysis[:decisions].first

    assert_equal "covered", decision_analysis.dig(:coverage, :decision_table, :status)
    assert_equal "partial", decision_analysis.dig(:coverage, :mcdc, :status)
    assert_equal 1, analysis.dig(:coverage, :decision_table, :fully_covered_decisions)
    assert_equal 2, analysis.dig(:coverage, :decision_table, :covered_rules)
    assert_equal 2, analysis.dig(:coverage, :decision_table, :required_rules)
    assert_equal 1, analysis.dig(:coverage, :decision_table, :impossible_rules)
    assert_in_delta 100.0, analysis.dig(:coverage, :decision_table, :percentage)
  end

  def test_alternative_decisions_have_no_decision_table
    decision = { id: "flow", kind: "multiway", tree: nil, conditions: [],
                 alternatives: [{ id: "a0", index: 0, expression: "1" }] }
    analysis = Branchproof::Analyzer.new(inventory: { decisions: [decision] }, evidence: { vectors: [] },
                                         limits: {}).call

    assert_nil analysis[:decisions].first[:decision_table]
    assert_equal 0, analysis.dig(:coverage, :decision_table, :decisions_analyzed)
  end
end
