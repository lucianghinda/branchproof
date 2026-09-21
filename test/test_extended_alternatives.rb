# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "branchproof/extended_alternative_runtime"

Branchproof::Runtime.extend(Branchproof::ExtendedAlternativeRuntime)

class TestExtendedAlternatives < Minitest::Test
  def teardown
    Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
  end

  def test_dynamic_case_splat_is_one_static_candidate_group_and_rewrites
    source = <<~RUBY
      def self.exercise(value, candidates)
        case value
        when *candidates
          :matched
        else
          :fallback
        end
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    decision = inventory[:decisions].find { |entry| entry[:context] == "case" }

    assert_equal(["*candidates", "else"], decision[:alternatives].map { |entry| entry[:expression] })
    refute_includes decision[:support_reasons], "unsupported_case_splat"
    assert_equal :matched, evaluate(rewritten, :value, [:value])
    assert_equal :fallback, evaluate(rewritten, :other, [:value])
    assert_equal [[true, nil], [false, true]], selected_vectors(decision)
  end

  def test_guarded_case_in_remains_supported_and_preserves_guard_laziness
    source = <<~RUBY
      def self.exercise(value, allowed)
        events = []
        result = case value
                 in Integer if (events << :guard; allowed)
                   :matched
                 else
                   :fallback
                 end
        [result, events]
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    decision = inventory[:decisions].find { |entry| entry[:context] == "case_in" }

    refute_includes decision[:support_reasons], "unsupported_pattern_guard"
    assert_equal [:matched, [:guard]], evaluate(rewritten, 1, true)
    assert_equal [:fallback, [:guard]], evaluate(rewritten, 1, false)
    assert_equal [[true, nil], [false, true]], selected_vectors(decision)
  end

  def test_safe_navigation_assignment_exposes_nil_skipped_and_executed_paths
    source = <<~RUBY
      class Box
        attr_accessor :value
        def initialize(value)
          @value = value
        end
      end

      def self.exercise(box, fallback)
        box&.value ||= fallback
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    decision = inventory[:decisions].find { |entry| entry[:context] == "or_assignment" }

    assert_equal(["receiver nil", "LHS truthy; RHS skipped", "LHS falsey; RHS executed"],
                 decision[:alternatives].map { |entry| entry[:expression] })
    refute_includes decision[:support_reasons], "unsupported_assignment_target"
    assert_nil evaluate(rewritten, :nil, :fallback)
    assert_equal :present, evaluate(rewritten, :present, :fallback)
    assert_equal :fallback, evaluate(rewritten, :empty, :fallback)
    assert_equal [[true, nil, nil], [false, true, nil], [false, false, true]], selected_vectors(decision)
  end

  private

  def selected_vectors(decision)
    assert_empty @evidence.snapshot[:diagnostics]
    assert_empty Branchproof::Runtime.diagnostics
    @evidence.snapshot[:vectors].select { |vector| vector[:decision_id] == decision[:id] }.map { |vector| vector[:values] }
  end

  def inventory_and_rewrite(source)
    Dir.mktmpdir("branchproof-extended-alternatives") do |directory|
      path = File.join(directory, "fixture.rb")
      File.write(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert_empty rewritten[:diagnostics]
      assert rewritten[:changed]
      @evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default, run_id: "alternatives")
      @evidence.register_test(test: { id: "Alternatives#exercise", name: "exercise", adapter: "minitest" })
      Branchproof::Runtime.boot(evidence: @evidence)
      Branchproof::Runtime.context(test_id: "Alternatives#exercise", phase: "body")
      return [inventory, rewritten[:bytes]]
    end
  end

  def evaluate(source, value, fallback)
    mod = Module.new
    mod.module_eval(source)
    if mod.const_defined?(:Box, false)
      box = if value == :nil
              nil
            else
              mod.const_get(:Box).new(value == :empty ? nil : value)
            end
      mod.exercise(box, fallback)
    else
      mod.exercise(value, fallback)
    end
  end
end
