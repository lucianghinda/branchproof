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

  def test_user_defined_each_records_one_entered_execution_for_nonempty_bag
    source = <<~RUBY
      class Bag
        include Enumerable

        def initialize(items)
          @items = items
        end

        def each
          @items.each { |item| yield item }
        end
      end

      def self.exercise(items)
        bag = Bag.new(items)
        seen = []
        bag.each { |item| seen << item }
        seen
      end
    RUBY

    inventory, snapshot = capture(source, [[1, 2, 3]])
    decision = inventory[:decisions].find { |row| row[:context] == "iteration" && row[:expression].include?("bag.each") }
    assert_equal 1, vectors(snapshot, decision).length
    assert_equal [[false, true]], vectors(snapshot, decision)
  end

  def test_nested_each_inside_define_method_records_each_outer_and_inner_once
    source = <<~RUBY
      class Bag
        include Enumerable

        def initialize(items)
          @items = items
        end

        def each
          @items.each { |item| yield item }
        end
      end

      define_singleton_method(:exercise) do |items|
        outer = Bag.new(items)
        inner = Bag.new(items)
        seen = []
        outer.each { |item| inner.each { |nested| seen << [item, nested] } }
        seen
      end
    RUBY

    inventory, snapshot = capture(source, [[1, 2]])
    decisions = inventory[:decisions].select { |row| row[:context] == "iteration" }
    outer = decisions.find { |row| row[:expression].include?("outer.each") }
    inner = decisions.find { |row| row[:expression].include?("inner.each") }
    assert_equal [[false, true]], vectors(snapshot, outer)
    assert_equal [[false, true]], vectors(snapshot, inner)
  end

  def test_stored_proc_invocation_inside_each_preserves_entered_evidence
    source = <<~RUBY
      def self.exercise(items)
        seen = []
        callback = proc { |item| seen << item }
        items.each { |item| callback.call(item) }
        seen
      end
    RUBY

    inventory, snapshot = capture(source, [[1, 2, 3]])
    decision = inventory[:decisions].find { |row| row[:context] == "iteration" }
    assert_equal [[false, true]], vectors(snapshot, decision)
  end

  def test_stored_proc_invoked_after_iteration_return_keeps_one_outer_execution
    source = <<~RUBY
      def self.exercise(items)
        callback = nil
        items.each { |item| callback = proc { item } }
        callback.call
      end
    RUBY

    inventory, snapshot = capture(source, [[1, 2, 3]])
    decision = inventory[:decisions].find { |row| row[:context] == "iteration" }
    assert_equal 1, vectors(snapshot, decision).length
    assert_equal [[false, true]], vectors(snapshot, decision)
  end

  def test_custom_iterator_deferred_callback_keeps_empty_and_later_entered_paths
    source = <<~RUBY
      class DeferredEach
        def initialize
          @callback = nil
        end

        def each(&block)
          @callback = block
          self
        end

        def emit(value)
          @callback.call(value)
        end
      end

      def self.exercise(emit)
        iterator = DeferredEach.new
        iterator.each { |value| value }
        iterator.emit(:value) if emit
        :done
      end
    RUBY

    inventory, snapshot = capture(source, [false, true])
    decision = inventory[:decisions].find { |row| row[:context] == "iteration" }
    assert_equal [[true, false], [false, true]], vectors(snapshot, decision)
    decision_vectors = snapshot[:vectors].select { |vector| vector[:decision_id] == decision[:id] }
    assert_equal [[true, false, 2], [false, true, 1]],
                 decision_vectors.map { |vector| vector.values_at(:values, :count) }.map(&:flatten)
    assert_empty(snapshot[:abort_counts].select { |id, _count| id == decision[:id] })
    assert_equal [], Thread.current[Branchproof::Runtime::FRAME_STATE_KEY]&.fetch(:frames)
  end

  def test_finished_iteration_callbacks_have_constant_allocation_cost
    recorder = Object.new
    recorder.define_singleton_method(:run_id) { "iteration-allocation" }
    recorder.define_singleton_method(:record) { |**_execution| nil }
    Branchproof::Runtime.boot(evidence: recorder)
    decision_id = "iteration-allocation-decision"
    Branchproof::Runtime.enter(decision_id)
    Branchproof::Runtime.flow_iteration_callback(decision_id, 2)

    GC.start
    before_small = GC.stat(:total_allocated_objects)
    10.times { Branchproof::Runtime.flow_iteration_callback(decision_id, 2) }
    small_delta = GC.stat(:total_allocated_objects) - before_small

    GC.start
    before_large = GC.stat(:total_allocated_objects)
    10_000.times { Branchproof::Runtime.flow_iteration_callback(decision_id, 2) }
    large_delta = GC.stat(:total_allocated_objects) - before_large

    assert_operator large_delta, :<=, small_delta + 20
  ensure
    Branchproof::Runtime.leave(decision_id) if decision_id && Branchproof::Runtime.send(:iteration_frame, decision_id)
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
