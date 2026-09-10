# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestExpandedBooleanSource < Minitest::Test
  def inventory_for(source)
    Dir.mktmpdir do |root|
      path = File.join(root, "sample.rb")
      File.binwrite(path, source)
      return Branchproof::Source.new(root: root, limits: Branchproof::Limits.default).inventory(paths: [path])
    end
  end

  def test_discovers_loop_and_subjectless_case_when_boolean_decisions
    inventory = inventory_for(<<~RUBY)
      if first
      end
      unless second
      end
      value if modifier
      value unless negative
      while loop_left && loop_right
      end
      begin
        work
      end until post_left || post_right
      begin
        work
      end while post_condition
      case
      when case_left && case_right
        :yes
      when second_case
        :no
      end
    RUBY

    decisions = inventory[:decisions]
    assert_equal(%w[if unless if unless while until while case_when case_when],
                 decisions.map { |decision| decision[:context] })
    assert(decisions.all? { |decision| decision[:kind] == "boolean" })
    assert_equal(["first", "second", "modifier", "negative", "loop_left && loop_right",
                  "post_left || post_right", "post_condition", "case_left && case_right", "second_case"],
                 decisions.map { |decision| decision[:expression] })
  end

  def test_keyword_boolean_nodes_use_ast_precedence_and_are_supported
    decision = inventory_for(<<~RUBY)[:decisions].first
      if first or second && third
      end
    RUBY

    assert_equal "boolean", decision[:kind]
    assert_equal "SUPPORTED", decision[:support_status]
    assert_empty decision[:support_reasons]
    assert_equal :or, decision[:tree][:type]
    assert_equal :and, decision[:tree][:right][:type]
    assert_equal(%w[first second third], decision[:conditions].map { |condition| condition[:expression] })
  end

  def test_unary_not_is_a_tree_node_and_conditions_are_operand_leaves
    decisions = inventory_for(<<~RUBY)[:decisions]
      if !(first && (second || third))
      end
      unless not ready
      end
    RUBY

    first, second = decisions
    assert_equal :not, first[:tree][:type]
    assert_equal :and, first[:tree][:child][:type]
    assert_equal :or, first[:tree][:child][:right][:type]
    assert_equal(%w[first second third], first[:conditions].map { |condition| condition[:expression] })
    assert_equal "!", first[:expression].byteslice(0, 1)
    assert_equal :not, second[:tree][:type]
    assert_equal(["ready"], second[:conditions].map { |condition| condition[:expression] })
    assert_empty first[:opaque_ranges]
    assert_empty second[:opaque_ranges]
  end

  def test_discovers_standalone_booleans_and_nested_atomic_call_arguments_once
    decisions = inventory_for(<<~RUBY)[:decisions]
      foo(first && second)
      foo(outer && bar(inner || last))
      if guarded_left && guarded_right
      end
    RUBY

    standalone = decisions.select { |decision| decision[:context] == "short_circuit" }
    assert_equal 3, standalone.length
    assert_equal(["first && second", "outer && bar(inner || last)", "inner || last"],
                 standalone.map { |decision| decision[:expression] })
    ranges = decisions.map { |decision| decision.values_at(:byte_start, :byte_length) }
    assert_equal ranges.length, ranges.uniq.length
    assert_equal(["guarded_left && guarded_right"],
                 decisions.select { |decision| decision[:context] == "if" }.map { |decision| decision[:expression] })
  end

  def test_boolean_inside_control_atom_is_separate_from_control_decision
    decisions = inventory_for(<<~RUBY)[:decisions]
      if allowed?(first && second)
      end
    RUBY

    assert_equal(%w[if short_circuit], decisions.map { |decision| decision[:context] })
    assert_equal(["allowed?(first && second)", "first && second"], decisions.map { |decision| decision[:expression] })
    assert_equal 2, decisions.map { |decision| decision.values_at(:byte_start, :byte_length) }.uniq.length
  end

  def test_pattern_predicates_are_boolean_and_guards_use_pattern_context
    decisions = inventory_for(<<~RUBY)[:decisions]
      value in Integer
      if value in Integer
        :matched
      end
      if (value in Integer) && other
        :compound
      end
      case value
      in {name: pattern} if guard
        :matched
      else
        :other
      end
    RUBY

    pattern_in = decisions.select { |decision| decision[:context] == "pattern_in" }
    ordinary_if = decisions.select { |decision| decision[:context] == "if" }
    pattern_guard = decisions.select { |decision| decision[:context] == "pattern_guard" }

    assert_equal 1, pattern_in.length
    assert_equal "boolean", pattern_in.first[:kind]
    assert_equal "value in Integer", pattern_in.first[:expression]
    assert_equal 1, pattern_in.first[:conditions].length
    assert_equal "value in Integer", pattern_in.first[:conditions].first[:expression]
    assert_equal :atom, pattern_in.first[:tree][:type]
    assert_equal 2, ordinary_if.length
    assert_equal(["value in Integer", "(value in Integer) && other"],
                 ordinary_if.map { |decision| decision[:expression] })
    assert_equal 1, pattern_guard.length
    assert_equal "boolean", pattern_guard.first[:kind]
    assert_equal "guard", pattern_guard.first[:expression]
    assert_equal(1, decisions.count { |decision| decision[:context] == "case_in" })
  end

  def test_subjectless_case_splat_is_visible_and_not_rewritten
    source = "case; when *values; :yes; else :no; end"
    inventory = inventory_for(source)
    decision = inventory[:decisions].first
    assert_equal "case_when", decision[:context]
    assert_equal "UNSUPPORTED", decision[:support_status]
    assert_includes decision[:support_reasons], "unsupported_case_splat"
    rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
    assert_equal source, rewritten[:bytes]
    assert_empty rewritten[:diagnostics]
  end

  def test_explicit_bang_method_call_remains_an_opaque_atom
    decision = inventory_for("if value.!; :yes; end")[:decisions].first
    assert_equal :atom, decision[:tree][:type]
    assert_equal "value.!", decision[:conditions].first[:expression]
    assert_equal 1, decision[:opaque_ranges].length
  end

  def test_existing_decision_identity_does_not_include_boolean_kind
    inventory = inventory_for("if left && right\nend\n")
    decision = inventory[:decisions].first

    expected = Branchproof::Records.decision_id(source_id: decision[:source_id], context: decision[:context],
                                                byte_start: decision[:byte_start],
                                                byte_length: decision[:byte_length], tree: decision[:tree])
    assert_equal expected, decision[:id]
    assert_equal "boolean", decision[:kind]
  end
end
