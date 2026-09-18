# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "rbconfig"
require "tempfile"

class TestFlowBehavior < Minitest::Test
  def test_case_keeps_native_matching_order_and_distinguishes_candidates
    source = <<~APP
      def self.exercise(value)
        events = []
        matcher = Object.new
        matcher.define_singleton_method(:===) { |candidate| events << [:match, candidate]; false }
        result = case value
                 when (events << :first; matcher), (events << :second; :yes)
                   :selected
                 when (events << :third; :other)
                   :other
                 else
                   :fallback
                 end
        [result, events]
      end
    APP
    inventory, evidence = compare(source, %i[yes other none])
    decision = inventory[:decisions].find { |entry| entry[:context] == "case" }
    vectors = evidence[:vectors].select { |vector| vector[:decision_id] == decision[:id] }
    assert_equal([[false, true, nil, nil], [false, false, true, nil], [false, false, false, true]],
                 vectors.map { |vector| vector[:values] })
    assert(vectors.all? { |vector| vector[:test_ids] == ["FlowTest#exercise"] })
  end

  def test_empty_case_branches_and_no_else_keep_nil_return
    source = <<~APP
      def self.exercise(value)
        case value
        when :empty
        when :filled then :value
        end
      end
    APP
    inventory, evidence = compare(source, %i[empty filled missing])
    decision = inventory[:decisions].find { |entry| entry[:context] == "case" }
    assert_equal(3, evidence[:vectors].count { |vector| vector[:decision_id] == decision[:id] })
  end

  def test_safe_navigation_observes_nil_and_false_and_keeps_lazy_arguments
    source = <<~APP
      def self.exercise(value)
        events = []
        receiver = value == :nil ? nil : false
        result = receiver&.to_s&.+((events << :argument; "!"))
        [result, events]
      end
    APP
    inventory, evidence = compare(source, [:nil, false])
    decisions = inventory[:decisions].select { |decision| decision[:context] == "safe_navigation" }
    assert_equal 2, decisions.length
    decisions.each do |decision|
      assert_equal([[true, false], [false, true]],
                   evidence[:vectors].select { |vector| vector[:decision_id] == decision[:id] }.map { |v| v[:values] })
    end
  end

  def test_assignment_targets_are_read_and_written_only_by_ruby
    source = <<~APP
      class Box
        attr_reader :events
        def initialize(value)
          @value = value
          @events = []
        end
        def item
          @events << :read
          @value
        end
        def item=(value)
          @events << [:write, value]
          @value = value
        end
        def [](key)
          @events << [:index_read, key]
          @value
        end
        def []=(key, value)
          @events << [:index_write, key, value]
          @value = value
        end
      end
      def self.exercise(value)
        box = Box.new(value)
        events = []
        local = value
        local ||= (events << :local; :built)
        @cached = value
        @cached &&= (events << :ivar; :authorized)
        box.item ||= (events << :call; :built)
        index_box = Box.new(value)
        index_box[(events << :index; :key)] &&= (events << :indexed; :authorized)
        [local, @cached, box.events, index_box.events, events]
      end
    APP
    inventory, evidence = compare(source, [nil, false, :present])
    decisions = inventory[:decisions].select { |decision| %w[or_assignment and_assignment].include?(decision[:context]) }
    assert_equal 4, decisions.length
    decisions.each do |decision|
      values = evidence[:vectors].select { |vector| vector[:decision_id] == decision[:id] }.map { |v| v[:values] }
      assert_includes values, [true, false]
      assert_includes values, [false, true]
    end
  end

  def test_selection_is_recorded_before_branch_or_rhs_raises
    source = <<~APP
      def self.exercise(value)
        case value
        when :case then raise "branch"
        else
          cache = nil
          cache ||= raise("rhs")
        end
      rescue RuntimeError => error
        error.message
      end
    APP
    inventory, evidence = compare(source, %i[case assignment])
    supported = inventory[:decisions].select { |decision| decision[:support_status] == "SUPPORTED" }
    assert(supported.all? { |decision| evidence[:vectors].any? { |vector| vector[:decision_id] == decision[:id] } })
    assert_empty evidence[:diagnostics]
  end

  def test_boolean_predicate_and_implicit_decision_at_same_range_are_both_recorded
    source = <<~APP
      def self.exercise(value)
        if value&.to_s
          :yes
        else
          :no
        end
      end
    APP
    inventory, evidence = compare(source, [nil, :value])
    assert_equal 2, inventory[:decisions].length
    assert_equal inventory[:decisions].map { |entry| entry[:id] }.sort,
                 evidence[:vectors].map { |entry| entry[:decision_id] }.uniq.sort
  end

  # rubocop:disable Style/GlobalVars
  def test_constant_class_variable_and_global_assignment_forms_keep_native_scope
    source = <<~APP
      CACHE = nil
      CACHE ||= :built
      ENABLED = false
      ENABLED &&= :unused
      module Store
        VALUE = :present
      end
      Store::VALUE ||= :unused
      def self.exercise(value)
        @@cache = value
        @@cache ||= :class_cache
        $branchproof_expansion_global = value
        $branchproof_expansion_global &&= :global_cache
        [CACHE, ENABLED, Store::VALUE, @@cache, $branchproof_expansion_global]
      end
    APP
    inventory, evidence = compare(source, [nil, :present])
    assignments = inventory[:decisions].select { |entry| %w[or_assignment and_assignment].include?(entry[:context]) }
    assert_equal 5, assignments.length
    assert(assignments.all? { |entry| evidence[:vectors].any? { |vector| vector[:decision_id] == entry[:id] } })
  ensure
    $branchproof_expansion_global = nil
  end

  # rubocop:enable Style/GlobalVars

  def test_native_pattern_matching_keeps_bindings_and_alternative_order
    source = <<~APP
      def self.exercise(value)
        result = case value
                 in [Integer => first, Integer => second] then first + second
                 in {status: 404} then :missing
                 else :other
                 end
        [result, defined?(first), first]
      end
    APP
    inventory, evidence = compare(source, [[1, 2], { status: 404 }, :other])
    decision = inventory[:decisions].find { |entry| entry[:context] == "case_in" }
    assert_equal([[true, nil, nil], [false, true, nil], [false, false, true]],
                 evidence[:vectors].select { |vector| vector[:decision_id] == decision[:id] }.map { |vector| vector[:values] })
  end

  def test_standalone_pattern_predicate_is_a_boolean_decision
    source = <<~APP
      def self.exercise(value)
        matched = (value in [Integer => item])
        [matched, item]
      end
    APP
    inventory, evidence = compare(source, [[1], :other])
    decision = inventory[:decisions].find { |entry| entry[:context] == "pattern_in" }
    assert_equal "boolean", decision[:kind]
    assert_equal([true, false], evidence[:vectors].map { |vector| vector[:outcome] })
  end

  def test_case_matching_runs_in_the_original_refinement_scope
    source = <<~APP
      module Matches
        refine Integer do
          def ===(value)
            value == :refined
          end
        end
      end
      using Matches
      def self.exercise(value)
        case value
        when 123 then :yes
        else :no
        end
      end
    APP
    original = run_refinement_fixture(source, :refined)
    rewritten = rewrite_source(source)
    instrumented = run_refinement_fixture(rewritten, :refined)
    assert_equal original, instrumented
    assert_equal "yes", instrumented
  end

  def test_defined_assignment_keeps_its_native_description_without_evaluating_rhs
    source = <<~APP
      def self.exercise(value)
        events = []
        local = value
        result = defined?(local ||= (events << :rhs))
        [result, events, local]
      end
    APP
    Dir.mktmpdir("branchproof-defined") do |directory|
      path = File.join(directory, "fixture.rb")
      File.write(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      decision = inventory[:decisions].find { |entry| entry[:context] == "defined" }
      assert_equal "boolean", decision[:kind]
      assert_equal "SUPPORTED", decision[:support_status]
      refute_includes decision[:support_reasons], "unsupported_defined_expression"
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert rewritten[:changed]
      original = Module.new
      original.module_eval(source, path)
      instrumented = Module.new
      instrumented.module_eval(rewritten[:bytes], path)
      assert_equal original.exercise(:value), instrumented.exercise(:value)
    end
  end

  def test_case_branch_return_and_no_else_keep_native_results
    source = <<~APP
      def self.exercise(value)
        case value
        when :return
          return :returned
        when :matched
          :matched
        end
        :after
      end
    APP
    inventory, evidence = compare(source, %i[return matched other])
    decision = inventory[:decisions].find { |entry| entry[:context] == "case" }
    values = evidence[:vectors].select { |vector| vector[:decision_id] == decision[:id] }.map { |vector| vector[:values] }
    assert_includes values, [true, nil, nil]
    assert_includes values, [false, true, nil]
    assert_includes values, [false, false, true]
  end

  def test_safe_navigation_compound_assignment_preserves_native_behavior
    source = <<~APP
      def self.exercise(value)
        value&.item ||= :built
      end
    APP
    Dir.mktmpdir("branchproof-safe-assignment") do |directory|
      path = File.join(directory, "fixture.rb")
      File.write(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      decision = inventory[:decisions].find { |entry| entry[:context] == "or_assignment" }
      assert_equal "multiway", decision[:kind]
      assert_equal "SUPPORTED", decision[:support_status]
      refute_includes decision[:support_reasons], "unsupported_assignment_target"
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert rewritten[:changed]
      refute_equal source, rewritten[:bytes]
    end
  end

  def test_empty_pattern_branch_is_selected_before_following_pattern
    source = <<~APP
      def self.exercise(value)
        case value
        in []
        in [Integer => item] then item
        else :other
        end
      end
    APP
    inventory, evidence = compare(source, [[], [1], :other])
    decision = inventory[:decisions].find { |entry| entry[:context] == "case_in" }
    vectors = evidence[:vectors].select { |vector| vector[:decision_id] == decision[:id] }
    values = vectors.map { |vector| vector[:values] }
    assert_includes values, [true, nil, nil]
    assert_includes values, [false, true, nil]
    assert_includes values, [false, false, true]
  end

  def test_case_in_without_else_keeps_no_matching_pattern_error_and_aborts
    source = <<~APP
      def self.exercise(value)
        case value
        in Integer => item then item
        end
      end
    APP
    inventory, snapshot = compare_exceptions(source, [1, :other])
    decision = inventory[:decisions].find { |entry| entry[:context] == "case_in" }
    outcomes = snapshot[:outcomes].map { |outcome| outcome[1] }
    vectors = snapshot[:evidence][:vectors].select { |vector| vector[:decision_id] == decision[:id] }.map { |vector| vector[:values] }
    assert_equal [1, "NoMatchingPatternError"], outcomes
    assert_equal 1, snapshot[:evidence][:abort_counts].fetch(decision[:id])
    assert_equal [[true]], vectors
  end

  private

  def rewrite_source(source)
    Dir.mktmpdir("branchproof-flow-rewrite") do |directory|
      path = File.join(directory, "fixture.rb")
      File.write(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert_empty rewritten[:diagnostics]
      assert rewritten[:changed]
      rewritten[:bytes]
    end
  end

  def run_refinement_fixture(source, value)
    Tempfile.create(["branchproof-refinement", ".rb"]) do |file|
      file.write(source)
      file.flush
      harness = <<~RUBY
        require "branchproof"
        load ARGV.fetch(0)
        puts exercise(ARGV.fetch(1).to_sym)
      RUBY
      output, error, status = Open3.capture3(RbConfig.ruby, "-I#{File.expand_path("../lib", __dir__)}", "-e", harness, file.path, value.to_s)
      assert status.success?, error
      output.lines.last.strip
    end
  end

  def compare_exceptions(source, arguments)
    Dir.mktmpdir("branchproof-flow-exceptions") do |directory|
      path = File.join(directory, "fixture.rb")
      File.write(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert_empty rewritten[:diagnostics]
      assert rewritten[:changed]

      original = Module.new
      original.module_eval(source, path)
      expected = arguments.map { |argument| capture_pattern_outcome(original, argument) }

      evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default, run_id: "flow")
      evidence.register_test(test: { id: "FlowTest#exercise", name: "exercise", adapter: "minitest" })
      Branchproof::Runtime.boot(evidence: evidence)
      Branchproof::Runtime.context(test_id: "FlowTest#exercise", phase: "body")
      instrumented = Module.new
      instrumented.module_eval(rewritten[:bytes], path)
      actual = arguments.map { |argument| capture_pattern_outcome(instrumented, argument) }
      assert_equal expected, actual
      snapshot = evidence.snapshot
      assert_empty snapshot[:diagnostics]
      assert_empty Branchproof::Runtime.diagnostics
      [inventory, { outcomes: actual, evidence: snapshot }]
    ensure
      Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
    end
  end

  def capture_pattern_outcome(mod, argument)
    [:ok, mod.exercise(argument)]
  rescue NoMatchingPatternError => e
    [:error, e.class.name, e.message]
  end

  def compare(source, arguments)
    Dir.mktmpdir("branchproof-flow") do |directory|
      path = File.join(directory, "fixture.rb")
      File.write(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert_empty rewritten[:diagnostics]
      assert rewritten[:changed]
      assert_equal source.count("\n"), rewritten[:bytes].count("\n")
      original = Module.new
      original.module_eval(source, path)
      expected = arguments.map { |argument| original.exercise(argument) }
      evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default, run_id: "flow")
      evidence.register_test(test: { id: "FlowTest#exercise", name: "exercise", adapter: "minitest" })
      Branchproof::Runtime.boot(evidence: evidence)
      Branchproof::Runtime.context(test_id: "FlowTest#exercise", phase: "body")
      instrumented = Module.new
      instrumented.module_eval(rewritten[:bytes], path)
      assert_equal(expected, arguments.map { |argument| instrumented.exercise(argument) })
      snapshot = evidence.snapshot
      assert_empty snapshot[:diagnostics]
      assert_empty Branchproof::Runtime.diagnostics
      [inventory, snapshot]
    ensure
      Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
    end
  end
end
