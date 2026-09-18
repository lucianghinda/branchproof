# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "branchproof/iteration_runtime"

Branchproof::Runtime.extend(Branchproof::IterationRuntime)

class TestIterationCoverage < Minitest::Test
  def test_for_preserves_bindings_and_measures_empty_and_entered
    source = "def self.exercise(items); item = nil; for item in items; break if item == 2; end; item; end"
    inventory, snapshot = capture(source, [[], [1], [2, 3]])
    decision = inventory[:decisions].find { |row| row[:context] == "iteration" }
    refute_nil decision
    assert_equal [[true, false], [false, true]], vectors(snapshot, decision)
  end

  def test_fetch_measures_fallback_instead_of_truthiness
    source = "def self.exercise(key); {nil: nil, false: false}.fetch(key) { :fallback }; end"
    inventory, snapshot = capture(source, %i[nil false missing])
    decision = inventory[:decisions].find { |row| row[:context] == "fetch_fallback" }
    refute_nil decision
    assert_equal [[true, false], [false, true]], vectors(snapshot, decision)
  end

  def test_required_matching_keeps_bindings_and_native_failure
    source = "def self.exercise(value); value => [Integer => item]; item; end"
    inventory, snapshot = capture(source, [[1], [:no], []])
    decision = inventory[:decisions].find { |row| row[:context] == "required_pattern" }
    refute_nil decision
    assert_equal [[true, nil], [false, true]], vectors(snapshot, decision)
  end

  def test_lazy_callback_has_no_coverage_until_demanded
    source = "def self.exercise(count); [1, 2].lazy.select { |v| v > 0 }.first(count); end"
    inventory, snapshot = capture(source, [0])
    decision = inventory[:decisions].find { |row| row[:context] == "lazy_callback" }
    refute_nil decision
    assert_empty vectors(snapshot, decision)
    _, demanded = capture(source, [1])
    assert_equal [[true]], vectors(demanded, decision)
  end

  def test_lazy_receiver_stored_in_a_variable_has_no_construction_coverage
    source = <<~RUBY
      def self.exercise(count)
        values = [1, 2].lazy
        values.select { |value| value > 0 }.first(count)
      end
    RUBY

    inventory, snapshot = capture(source, [0])
    decision = inventory[:decisions].find { |row| row[:context] == "iteration" }
    assert_empty vectors(snapshot, decision)

    _, demanded = capture(source, [1])
    assert_equal [[false, true]], vectors(demanded, decision)
  end

  def test_deferred_lazy_callback_does_not_probe_an_outer_boolean_frame
    source = <<~RUBY
      def self.exercise(trigger)
        values = [1].lazy
        if trigger && values.select { |value| value > 0 }.first(1).any?
          :matched
        else
          :fallback
        end
      end
    RUBY

    inventory, snapshot = capture(source, [false, true])
    decision = inventory[:decisions].find { |row| row[:context] == "iteration" }
    assert_equal [[false, true]], vectors(snapshot, decision)
    assert_empty snapshot[:diagnostics]
  end

  def test_lazy_protocol_does_not_call_overridden_is_a_on_an_eager_receiver
    source = <<~RUBY
      class EagerLazy
        def initialize(values)
          @values = values
        end

        def lazy
          self
        end

        def is_a?(_klass)
          raise "instrumentation must not call is_a?"
        end

        def select
          @values.select { |value| yield value }
        end
      end

      def self.exercise(_ignored)
        EagerLazy.new([1]).lazy.select { |value| value > 0 }
      end
    RUBY

    inventory, snapshot = capture(source, [nil])
    decision = inventory[:decisions].find { |row| row[:context] == "lazy_callback" }
    assert_equal [[true]], vectors(snapshot, decision)
  end

  private

  def vectors(snapshot, decision)
    snapshot[:vectors].select { |row| row[:decision_id] == decision[:id] }.map { |row| row[:values] }
  end

  def capture(source, arguments)
    Dir.mktmpdir("branchproof-iteration") do |directory|
      path = File.join(directory, "example.rb")
      File.write(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert_empty rewritten[:diagnostics]
      native = Module.new
      native.module_eval(source, path)
      expected = arguments.map { |value| outcome(native, value) }
      evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default, run_id: "iteration")
      evidence.register_test(test: { id: "Iteration#exercise", name: "exercise", adapter: "minitest" })
      Branchproof::Runtime.boot(evidence: evidence)
      Branchproof::Runtime.context(test_id: "Iteration#exercise", phase: "body")
      measured = Module.new
      measured.module_eval(rewritten[:bytes], path)
      assert_equal(expected, arguments.map { |value| outcome(measured, value) })
      assert_empty evidence.snapshot[:diagnostics]
      assert_empty Branchproof::Runtime.diagnostics
      [inventory, evidence.snapshot]
    ensure
      Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
    end
  end

  def outcome(mod, value)
    [:value, mod.exercise(value)]
  rescue NoMatchingPatternError => e
    [:error, e.class.name, e.message]
  end
end
