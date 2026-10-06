# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestGuardSource < Minitest::Test
  def test_terminal_guard_measures_only_the_left_predicate
    ["raise('missing')", "fail('missing')", "return", "(return :missing)",
     "(raise('missing'))"].each do |operand|
      decisions = inventory("def pick(value)\nvalue || #{operand}\nend\n")
      assert_equal 1, decisions.size, operand
      decision = decisions.first
      assert_equal "guard", decision[:context], operand
      assert_equal "value", decision[:expression]
      assert_equal(["value"], decision[:conditions].map { |condition| condition[:expression] })
      assert_equal "SUPPORTED", decision[:support_status]
    end
  end

  def test_loop_jumps_are_guards
    %w[break next redo].each do |jump|
      decisions = inventory("loop { value || #{jump} }\n")
      assert_equal 1, decisions.count { |decision| decision[:context] == "guard" }, jump
    end
    decisions = inventory("begin\nwork\nrescue\nvalue || retry\nend\n")
    assert_equal(1, decisions.count { |decision| decision[:context] == "guard" })
  end

  def test_compound_left_predicate_is_not_duplicated
    decisions = inventory("a || b || raise('missing')\n")
    assert_equal 1, decisions.size
    assert_equal "guard", decisions.first[:context]
    assert_equal(%w[a b], decisions.first[:conditions].map { |condition| condition[:expression] })
  end

  def test_rhs_nested_decisions_remain_separate
    decisions = inventory("value || raise(a && b)\n")
    assert_equal(%w[guard short_circuit], decisions.map { |decision| decision[:context] })
    assert_equal(["value", "a && b"], decisions.map { |decision| decision[:expression] })
  end

  def test_other_boolean_expressions_keep_their_existing_meaning
    ["if value || raise('missing'); work; end", "value or raise('missing')",
     "value || receiver.raise('missing')", "value || Kernel.raise('missing')",
     "value || raise('missing') || other", "value || begin; raise('missing'); rescue; false; end",
     "value || (work; raise('missing'))"].each do |source|
      refute_includes inventory(source).map { |decision| decision[:context] }, "guard", source
    end
  end

  private

  def inventory(source)
    Dir.mktmpdir do |root|
      path = File.join(root, "fixture.rb")
      File.write(path, source)
      Branchproof::Source.new(root: root, limits: Branchproof::Limits.default).inventory(paths: [path])[:decisions]
    end
  end
end
