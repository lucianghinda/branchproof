# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestValueScopeReview < Minitest::Test
  def test_bitwise_results_are_not_decisions_but_comparison_records_both_values
    Dir.mktmpdir("branchproof-scope-") do |root|
      File.write(File.join(root, "construct.rb"), <<~RUBY)
        def mask(value)
          [value & 1, value | 1, value ^ 1]
        end

        def compare(left, right)
          left == right
        end
      RUBY
      inventory = Branchproof::Source.new(root: root, limits: Branchproof::Limits.default)
                                     .inventory(paths: ["construct.rb"])
      refute(inventory.fetch(:decisions).any? { |decision| decision[:context] == "bitwise" })
      assert_equal(["predicate"], inventory.fetch(:decisions).map { |decision| decision[:context] })
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory.fetch(:source_units).first)
      assert rewritten.fetch(:changed)
      assert_empty rewritten.fetch(:diagnostics)

      evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default, run_id: "scope")
      evidence.register_test(test: { id: "scope-test", name: "scope-test", adapter: "test" })
      Branchproof::Runtime.boot(evidence: evidence)
      Branchproof::Runtime.context(test_id: "scope-test", phase: "body")
      namespace = Module.new
      namespace.module_eval(rewritten.fetch(:bytes), File.join(root, "construct.rb"), 1)
      runner = Object.new.extend(namespace)
      assert_equal [[0, 3, 3], [1, 3, 2]], [runner.mask(2), runner.mask(3)]
      assert_equal [true, false], [runner.compare(1, 1), runner.compare(1, 2)]
      vectors = evidence.snapshot.fetch(:vectors)
      assert_equal 2, vectors.length
      assert_equal(1, vectors.count { |vector| vector.fetch(:values).fetch(0) == true })
      assert_equal(1, vectors.count { |vector| vector.fetch(:values).fetch(0) == false })
    ensure
      Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
    end
  end
end
