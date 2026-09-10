# frozen_string_literal: true

require "test_helper"
require "branchproof/evidence"
require "branchproof/instrumenter"
require "branchproof/limits"
require "branchproof/source"
require "json"
require "open3"
require "rbconfig"
require "tempfile"

class TestExpandedBooleanBehavior < Minitest::Test
  TEST_ID = "expanded-boolean-test"

  def test_loop_forms_repeat_predicates_and_preserve_values_and_side_effects
    source = <<~RUBY
      def mark(events, key, value = true)
        events << key
        value
      end

      def loop_forms
        events = []
        count = 0
        while mark(events, :while_left) && count < 2
          count += 1
        end

        modifier_count = 0
        mark(events, :modifier_body) while modifier_count < 2 && (modifier_count += 1)

        post_count = 0
        begin
          mark(events, :post_body)
          post_count += 1
        end while post_count < 2 && mark(events, :post_right)

        until count >= 4 || mark(events, :until_guard, false)
          count += 1
        end

        until_count = 0
        mark(events, :until_modifier_body) until until_count >= 2 || (until_count += 1)
        [count, modifier_count, post_count, until_count, events]
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    decisions = inventory[:decisions]
    loop_decisions = decisions.select { |decision| %w[while until].include?(decision[:context]) }
    contexts = loop_decisions.map { |decision| decision[:context] }
    assert_equal %w[while while while until until], contexts
    assert(loop_decisions.all? { |decision| decision[:kind].to_s == "boolean" })
    assert(loop_decisions.all? { |decision| decision[:support_status] == "SUPPORTED" })

    original = run_fixture(source, "loop_forms")
    instrumented = run_fixture(rewritten[:bytes], "loop_forms")
    assert_equal original[:result], instrumented[:result]
    assert_equal original[:events], instrumented[:events]
    assert_equal [4, 2, 2, 1], instrumented[:result].first(4)

    evidence = evidence_for(inventory, instrumented[:executions])
    vectors = evidence.snapshot[:vectors]
    loop_ids = loop_decisions.map { |decision| decision[:id] }
    loop_vectors = vectors.select { |vector| loop_ids.include?(vector[:decision_id]) }
    assert_operator loop_vectors.sum { |vector| vector[:count] }, :>=, 10
    assert(loop_vectors.all? { |vector| vector[:test_ids] == [TEST_ID] })
    assert(loop_vectors.all? { |vector| vector[:phases_by_test][TEST_ID] == ["body"] })
  end

  def test_break_next_redo_and_return_keep_application_behavior_and_frame_state
    source = <<~RUBY
      def controls(mode, events)
        case mode
        when :break
          i = 0
          while (events << :break_predicate) && i < 3
            i += 1
            break :broken if i == 2
          end
        when :next
          values = []
          i = 0
          while i < 3 && events << :next_predicate
            i += 1
            next if i == 1
            values << i
          end
          values
        when :redo
          i = 0
          redone = false
          while (events << :redo_predicate) && i < 2
            unless redone
              redone = true
              events << :redo
              redo
            end
            i += 1
          end
          i
        when :return
          while events.tap { return :returned }
          end
        end
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    loop_decisions = inventory[:decisions].select { |decision| decision[:context] == "while" }
    assert_operator loop_decisions.length, :>=, 4
    assert(loop_decisions.all? { |decision| decision[:kind].to_s == "boolean" })

    calls = <<~RUBY
      %i[break next redo return].map do |mode|
        events = []
        [mode, controls(mode, events), events]
      end
    RUBY
    original = run_fixture(source, "(#{calls})")
    instrumented = run_fixture(rewritten[:bytes], "(#{calls})")
    assert_equal original[:result], instrumented[:result]
    assert_equal original[:events], instrumented[:events]
    assert_equal "returned", instrumented[:result].last[1]

    evidence = evidence_for(inventory, instrumented[:executions])
    snapshot = evidence.snapshot
    assert_operator snapshot[:abort_counts].values.sum, :>=, 1
    assert(snapshot[:vectors].all? { |vector| vector[:test_ids] == [TEST_ID] })
    assert(snapshot[:vectors].all? { |vector| vector[:phases_by_test][TEST_ID] == ["body"] })
  end

  def test_subjectless_case_instruments_each_candidate_in_source_order
    source = <<~RUBY
      def subjectless(first, second, third, fourth, events)
        case
        when mark(events, :first, first), mark(events, :second, second)
          :first_case
        when mark(events, :third, third) && mark(events, :fourth, fourth)
          :second_case
        else
          :none
        end
      end

      def mark(events, key, value)
        events << key
        value
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    decisions = inventory[:decisions].select { |decision| decision[:context] == "case_when" }
    assert_equal 3, decisions.length
    assert_equal decisions.sort_by { |decision| decision[:byte_start] }, decisions
    expressions = decisions.map { |decision| decision[:expression].split("(").first }
    assert_equal %w[mark mark mark], expressions
    assert(decisions.all? { |decision| decision[:kind].to_s == "boolean" })
    assert(decisions.all? { |decision| decision[:support_status] == "SUPPORTED" })
    condition_counts = decisions.map { |decision| decision[:conditions].length }
    assert_equal [1, 1, 2], condition_counts

    calls = <<~RUBY
      [[true, true, false, false], [false, true, false, false],
       [false, false, true, true], [false, false, false, true]].map do |flags|
        events = []
        [subjectless(*flags, events), events]
      end
    RUBY
    original = run_fixture(source, "(#{calls})")
    instrumented = run_fixture(rewritten[:bytes], "(#{calls})")
    assert_equal original[:result], instrumented[:result]
    assert_equal original[:events], instrumented[:events]
    assert_equal [["first_case", ["first"]], ["first_case", %w[first second]],
                  ["second_case", %w[first second third fourth]],
                  ["none", %w[first second third]]], instrumented[:result]
  end

  def test_keyword_boolean_precedence_and_assignments_survive_instrumentation
    source = <<~RUBY
      def keyword(left, right, events)
        assigned_and = left and mark(events, :and_rhs, right)
        assigned_or = left or mark(events, :or_rhs, right)
        parenthesized = (left or mark(events, :parenthesized_or_rhs, right))
        [assigned_and, assigned_or, parenthesized, events]
      end

      def mark(events, key, value)
        events << key
        value
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    decisions = inventory[:decisions].select { |decision| decision[:context] == "short_circuit" }
    assert_equal 3, decisions.length
    tree_types = decisions.map { |decision| decision[:tree][:type] }
    assert_equal %i[and or or], tree_types
    assert(decisions.all? { |decision| decision[:kind].to_s == "boolean" })
    assert(decisions.all? { |decision| decision[:support_status] == "SUPPORTED" })

    calls = <<~RUBY
      [[true, false], [false, true]].map do |left, right|
        events = []
        [keyword(left, right, events), events]
      end
    RUBY
    original = run_fixture(source, "(#{calls})")
    instrumented = run_fixture(rewritten[:bytes], "(#{calls})")
    assert_equal original[:result], instrumented[:result]
    assert_equal original[:events], instrumented[:events]
    assert_equal [[[true, true, true, ["and_rhs"]], ["and_rhs"]],
                  [[false, false, true, %w[or_rhs parenthesized_or_rhs]], %w[or_rhs parenthesized_or_rhs]]],
                 instrumented[:result]
  end

  def test_nested_not_uses_logical_tree_and_custom_bang_keeps_its_application_semantics
    source = <<~RUBY
      class CustomBang
        def initialize(value, events)
          @value = value
          @events = events
        end

        def !
          @events << :custom_bang
          @value
        end
      end

      def nested_not(first, second)
        if !(first && !second)
          true
        else
          false
        end
      end

      def custom_bang(value, events)
        object = CustomBang.new(value, events)
        !object
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    logical = inventory[:decisions].find { |decision| decision[:expression] == "!(first && !second)" }
    refute_nil logical
    assert_equal "boolean", logical[:kind].to_s
    assert_equal :not, logical[:tree][:type]
    assert_equal :and, logical[:tree][:child][:type]
    assert_equal :not, logical[:tree][:child][:right][:type]

    calls = <<~RUBY
      values = [[true, true], [true, false], [false, true], [false, false]].map do |first, second|
        [first, second, nested_not(first, second)]
      end
      events = []
      [values, custom_bang(true, events), custom_bang(false, events), events]
    RUBY
    original = run_fixture(source, "(#{calls})")
    instrumented = run_fixture(rewritten[:bytes], "(#{calls})")
    assert_equal original[:result], instrumented[:result]
    assert_equal original[:events], instrumented[:events]
    assert_equal [true, false, true, true], instrumented[:result].first.map(&:last)
    assert_equal %w[custom_bang custom_bang], instrumented[:result].last

    custom = inventory[:decisions].select { |decision| decision[:expression] == "!object" }
    assert(custom.empty? || custom.all? { |decision| decision[:support_status] == "UNSUPPORTED" })
  end

  def test_standalone_short_circuit_has_one_decision_and_aggregates_attributed_vectors
    source = <<~RUBY
      def standalone(left, right, events)
        left && mark(events, right)
      end

      def mark(events, value)
        events << :rhs
        value
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    decisions = inventory[:decisions].select { |decision| decision[:context] == "short_circuit" }
    assert_equal 1, decisions.length
    decision = decisions.fetch(0)
    assert_equal "boolean", decision[:kind].to_s
    assert_equal :and, decision[:tree][:type]

    calls = <<~RUBY
      [[true, true], [true, false], [false, true]].map do |left, right|
        events = []
        [standalone(left, right, events), events]
      end
    RUBY
    original = run_fixture(source, "(#{calls})")
    instrumented = run_fixture(rewritten[:bytes], "(#{calls})")
    assert_equal original[:result], instrumented[:result]
    assert_equal original[:events], instrumented[:events]

    evidence = evidence_for(inventory, instrumented[:executions])
    vectors = evidence.snapshot[:vectors].select { |vector| vector[:decision_id] == decision[:id] }
    vector_count = vectors.sum { |vector| vector[:count] }
    assert_equal 3, vector_count
    vector_shapes = vectors.map { |vector| vector.values_at(:values, :outcome) }
    assert_equal [[[true, true], true], [[true, false], false], [[false, nil], false]], vector_shapes
    assert(vectors.all? { |vector| vector[:test_ids] == [TEST_ID] })
    assert(vectors.all? { |vector| vector[:phases_by_test][TEST_ID] == ["body"] })
  end

  private

  def inventory_and_rewrite(source)
    Dir.mktmpdir("branchproof-expanded") do |directory|
      path = File.join(directory, "fixture.rb")
      File.binwrite(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert rewritten[:changed], rewritten.inspect
      return [inventory, rewritten]
    end
  end

  def run_fixture(bytes, expression)
    Tempfile.create(["branchproof-expanded", ".rb"]) do |file|
      file.write(bytes)
      file.flush
      harness = <<~RUBY
        require "json"
        require "branchproof"

        class Recorder
          attr_reader :executions

          def initialize
            @executions = []
          end

          def run_id = "expanded-run"
          def register_test(test:) = { status: "registered" }
          def record(execution:)
            @executions << execution
            { status: "recorded" }
          end
        end

        recorder = Recorder.new
        Branchproof::Runtime.boot(evidence: recorder)
        load ARGV.fetch(0)
        Branchproof::Runtime.context(test_id: #{TEST_ID.inspect}, phase: "body")
        $events = [] unless defined?($events)
        result = (#{expression})
        puts JSON.generate(result: result, events: ($events || []), executions: recorder.executions)
      RUBY
      output, error, status = Open3.capture3(RbConfig.ruby, "-I#{File.expand_path("../lib", __dir__)}", "-e",
                                             harness, file.path)
      assert status.success?, error
      JSON.parse(output).transform_keys(&:to_sym).tap do |parsed|
        parsed[:result] = symbolize_runtime(parsed[:result])
        parsed[:events] = symbolize_runtime(parsed[:events])
        parsed[:executions] = parsed[:executions].map { |execution| symbolize_runtime(execution) }
      end
    end
  end

  def evidence_for(inventory, executions)
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default, run_id: "expanded-run")
    evidence.register_test(test: { id: TEST_ID, adapter: "fixture", name: TEST_ID, phase_counts: {} })
    executions.each do |execution|
      result = evidence.record(execution: execution)
      assert_equal "recorded", result[:status], [execution, result].inspect
    end
    evidence
  end

  def symbolize_runtime(value)
    return value.map { |item| symbolize_runtime(item) } if value.is_a?(Array)
    return value.transform_keys(&:to_sym).transform_values { |item| symbolize_runtime(item) } if value.is_a?(Hash)

    value
  end
end
