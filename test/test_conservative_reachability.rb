# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestConservativeReachability < Minitest::Test
  def inventory_for(source)
    Dir.mktmpdir do |root|
      path = File.join(root, "sample.rb")
      File.write(path, source)
      inventory = Branchproof::Source.new(root: root, limits: Branchproof::Limits.default).inventory(paths: [path])
      yield inventory[:decisions].first
    end
  end

  def table_for(decision)
    Branchproof::DecisionTable.build(decision: decision, vectors: [], reachability: true)
  end

  def test_mutation_between_comparisons_is_not_statistically_excluded
    inventory_for("x = 11\nif x > 10 && (x = 0) && x < 5\nend\n") do |decision|
      assert(decision[:conditions].all? { |condition| condition[:constraint_safe] == false })
      table = table_for(decision)
      assert(table[:rules].any? { |rule| rule[:conditions] == %w[true true true] && rule[:reachability] == "unknown" })
    end
  end

  def test_instance_mutation_and_custom_operator_remain_unknown
    inventory_for("if @x > 10 && (@x = 0) && @x < 5\nend\n") do |decision|
      assert(decision[:conditions].all? { |condition| condition[:constraint_safe] == false })
      table = table_for(decision)
      assert(table[:rules].any? { |rule| rule[:conditions] == %w[true true true] && rule[:reachability] == "unknown" })
    end

    value_class = Class.new do
      def initialize
        @value = 11
      end

      def >(_other)
        @value = 0
        true
      end

      def <(other)
        @value < other
      end
    end
    value = value_class.new
    assert_equal true, (value > 10 && value < 5)

    inventory_for("x = CustomValue.new\nif x > 10 && x < 5\nend\n") do |decision|
      assert_equal([false, false], decision[:conditions].map { |condition| condition[:constraint_safe] })
      table = table_for(decision)
      assert(table[:rules].any? { |rule| rule[:conditions] == %w[true true] && rule[:reachability] == "unknown" })
    end
  end

  def test_mixed_numeric_equality_and_nan_partition_are_not_excluded
    inventory_for("x = 1\nif x == 1 && x == 1.0\nend\n") do |decision|
      assert(decision[:conditions].all? { |condition| condition[:constraint_safe] == false })
      table = table_for(decision)
      assert(table[:rules].any? { |rule| rule[:conditions] == %w[true true] && rule[:reachability] == "unknown" })
    end

    inventory_for("x = Float::NAN\nif x < 0 || x >= 0\nend\n") do |decision|
      nan = Float::NAN
      assert_equal false, (nan.negative? || nan >= 0)
      table = table_for(decision)
      assert(table[:rules].any? { |rule| rule[:conditions] == %w[false false] && rule[:reachability] == "unknown" })
    end
  end

  def test_repeated_bare_local_reads_are_the_only_safe_constraints
    inventory_for("ready = true\nif ready && ready\nend\n") do |decision|
      assert_equal([true, true], decision[:conditions].map { |condition| condition[:constraint_safe] })
    end

    inventory_for("@ready = true\nif @ready && @ready\nend\n") do |decision|
      assert_equal([false, false], decision[:conditions].map { |condition| condition[:constraint_safe] })
    end

    inventory_for("ready = true\nif ready && !ready\nend\n") do |decision|
      assert_equal([false, false], decision[:conditions].map { |condition| condition[:constraint_safe] })
    end

    inventory_for("ready = true\nif (ready.to_s) && ready\nend\n") do |decision|
      assert_equal([false, false], decision[:conditions].map { |condition| condition[:constraint_safe] })
    end
  end
end
