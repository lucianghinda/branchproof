# frozen_string_literal: true

require "test_helper"
require "prism"

class TestConstraints < Minitest::Test
  def constraint_for(source, local: "value")
    program = Prism.parse("#{local} = nil\n#{source}\n").value
    node = program.statements.body.last
    Branchproof::Constraints.for_node(node)
  end

  def test_numeric_comparisons_normalize_to_subject_operator_and_literal
    constraint = constraint_for("age >= 18", local: "age")

    assert_equal({ kind: "local", name: "age" }, constraint[:subject])
    assert_equal ">=", constraint[:operator]
    assert_equal({ type: "integer", value: 18 }, constraint[:literal])
  end

  def test_literal_on_the_left_flips_the_operator
    assert_equal ">=", constraint_for("18 <= age", local: "age")[:operator]
    assert_equal "<", constraint_for("65 > age", local: "age")[:operator]
  end

  def test_nil_predicate_and_nil_equality_normalize_identically
    assert_equal constraint_for("value.nil?"), constraint_for("value == nil")
    assert_equal({ type: "nil", value: nil }, constraint_for("value.nil?")[:literal])
    assert_equal "==", constraint_for("value.nil?")[:operator]
  end

  def test_bare_subject_is_a_truthiness_constraint_not_boolean_equality
    constraint = constraint_for("value")

    assert_equal "truthy", constraint[:operator]
    assert_nil constraint[:literal]
    refute_equal constraint_for("value == true"), constraint
  end

  def test_supported_subject_kinds
    kinds = { "@state" => "instance", "$state" => "global", "STATE" => "constant" }
    kinds.each do |expression, kind|
      constraint = Branchproof::Constraints.for_node(Prism.parse("#{expression} == 1").value.statements.body.first)

      assert_equal kind, constraint[:subject][:kind], expression
    end
  end

  def test_method_call_subjects_and_string_literals_stay_unsupported
    assert_nil constraint_for("user.age >= 18")
    assert_nil constraint_for("value == \"active\"")
    assert_nil constraint_for("value&.nil?")
    assert_nil constraint_for("premium?")
    assert_nil constraint_for("value.between?(1, 5)")
  end

  def test_numeric_operators_reject_non_numeric_literals
    assert_nil constraint_for("value > :active")
    assert_nil constraint_for("value < nil")
  end

  def solve(*pairs)
    solver = Branchproof::Constraints::Solver.new
    pairs.each do |source, truth|
      reason = solver.add(constraint_for(source, local: subject_of(source)), truth)
      return reason if reason
    end
    nil
  end

  def subject_of(source) = source[/\A[A-Za-z_][A-Za-z0-9_]*/]

  def test_numeric_bound_contradictions
    assert_equal "conflicting_numeric_bounds", solve(["x > 10", true], ["x <= 10", true])
    assert_equal "conflicting_numeric_bounds", solve(["x >= 20", true], ["x < 5", true])
    assert_equal "conflicting_numeric_bounds", solve(["x < 0", true], ["x >= 0", true])
    assert_equal "conflicting_numeric_bounds", solve(["x > 10", true], ["x < 5", true])
  end

  def test_falsified_comparisons_invert_the_bound
    assert_equal "conflicting_numeric_bounds", solve(["x < 5", false], ["x < 5", true])
    assert_nil solve(["x >= 18", true], ["x < 65", true])
    assert_nil solve(["x >= 18", false], ["x < 65", true])
  end

  def test_equality_contradictions
    assert_equal "conflicting_equalities", solve(["x == 10", true], ["x != 10", true])
    assert_equal "conflicting_equalities", solve(["x == 5", true], ["x == 10", true])
    assert_equal "equality_outside_numeric_range", solve(["x == 5", true], ["x > 10", true])
    assert_equal "conflicting_equalities", solve(["x == :active", true], ["x == :disabled", true])
    assert_nil solve(["x == :active", true], ["x != :disabled", true])
  end

  def test_nil_contradictions
    assert_equal "nil_conflict", solve(["x.nil?", true], ["x.nil?", false])
    assert_equal "nil_conflict", solve(["x.nil?", true], ["x != nil", true])
    assert_equal "nil_conflict", solve(["x.nil?", true], ["x == 5", true])
    assert_nil solve(["x.nil?", false], ["x != nil", true])
  end

  def test_truthiness_contradictions_preserve_ruby_semantics
    assert_equal "boolean_literal_conflict", solve(["x", true], ["x == false", true])
    assert_equal "nil_conflict", solve(["x", true], ["x.nil?", true])
    assert_equal "boolean_literal_conflict", solve(["x", false], ["x == 5", true])
    assert_equal "boolean_literal_conflict", solve(["x", true], ["x", false])
    # A truthy value is not `== true`, so a truthy requirement and any non-falsey
    # equality remain satisfiable together.
    assert_nil solve(["x", true], ["x == 5", true])
    assert_nil solve(["x", false], ["x.nil?", true])
  end

  def test_distinct_subjects_never_interact
    assert_nil solve(["foo >= 18", true], ["bar < 5", true])
  end

  def test_unsupported_constraints_are_ignored_rather_than_guessed
    solver = Branchproof::Constraints::Solver.new

    assert_nil solver.add(nil, true)
    assert_nil solver.add({ subject: { kind: "method", name: "x" }, operator: "==", literal: nil }, true)
  end

  def test_reason_codes_have_stable_human_messages
    Branchproof::Constraints::REASONS.each do |reason|
      refute_empty Branchproof::Constraints.message(reason)
    end
  end
end
