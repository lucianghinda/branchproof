# frozen_string_literal: true

# rubocop:disable Security/Eval, Style/DocumentDynamicEvalDefinition

require "test_helper"
require "prism"
require "branchproof/decision_syntax"
require "branchproof/exception_syntax"
require "branchproof/exception_instrumentation"
require "branchproof/exception_runtime"
require "branchproof/instrumenter"
require "branchproof/source"
require "branchproof/evidence"
require "branchproof/limits"

class TestExceptionCoverage < Minitest::Test
  class SourceHarness
    include Branchproof::DecisionSyntax
    include Branchproof::ExceptionSyntax

    def walk(node, &block)
      yield node
      node.child_nodes.each { |child| walk(child, &block) if child }
    end

    def text_value(value, encoding)
      value.dup.force_encoding(encoding).encode("UTF-8")
    end

    def unsupported_reasons(*)
      []
    end
  end

  class ExceptionSource < Branchproof::Source
    include Branchproof::ExceptionSyntax
  end

  class ExceptionInstrumenter < Branchproof::Instrumenter
    include Branchproof::ExceptionInstrumentation
  end

  def setup
    Branchproof::Runtime.extend(Branchproof::ExceptionRuntime)
  end

  def test_discovers_protected_region_without_standalone_rescue_duplicates
    source = <<~RUBY
      begin
        work
      rescue ArgumentError
        recover
      rescue StandardError
        general
      end
    RUBY

    records = decisions(source)

    assert_equal 1, records.length
    decision = records.fetch(0)
    assert_equal "exception", decision[:kind]
    assert_equal "rescue", decision[:context]
    assert_equal(["normal", "rescue ArgumentError", "rescue StandardError", "unhandled"],
                 decision[:alternatives].map { |alternative| alternative[:expression] })
    assert_equal "SUPPORTED", decision[:support_status]
  end

  def test_discovers_modifier_rescue_as_a_native_exception_decision
    decision = decisions("Integer(value) rescue 0").fetch(0)

    assert_equal "exception", decision[:kind]
    assert_equal(%w[normal rescue unhandled],
                 decision[:alternatives].map { |alternative| alternative[:expression] })
    assert_equal "SUPPORTED", decision[:support_status]
  end

  def test_instruments_native_normal_handled_and_unhandled_paths
    source = <<~RUBY
      def exercise(mode)
        begin
          raise ArgumentError if mode == :handled
          raise IOError if mode == :unhandled
          :normal
        rescue ArgumentError
          :handled
        end
      end
    RUBY
    inventory, rewritten = instrumented(source)
    decision = inventory[:decisions].find { |entry| entry[:kind] == "exception" }
    assert_equal "SUPPORTED", decision[:support_status]
    assert_empty rewritten[:diagnostics]

    original = eval("#{source}\nexercise(:normal)\n", TOPLEVEL_BINDING, __FILE__, __LINE__)
    values = %i[normal handled].map { |mode| eval("exercise(#{mode.inspect})", TOPLEVEL_BINDING, __FILE__, __LINE__) }
    assert_equal %i[normal handled], values
    assert_equal :normal, original

    evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default,
                                         run_id: "exception-test")
    Branchproof::Runtime.boot(evidence: evidence)
    eval(rewritten[:bytes], TOPLEVEL_BINDING)
    %i[normal handled].each { |mode| exercise(mode) }
    error = assert_raises(IOError) { exercise(:unhandled) }
    assert_equal "IOError", error.class.name
    vectors = Branchproof::Runtime.snapshot.fetch(:vectors)
    vector = vectors.select { |entry| entry[:decision_id] == decision[:id] }
    assert_equal 3, vector.length
    assert_equal([[true, nil, nil], [false, true, nil], [false, false, true]],
                 vector.map { |entry| entry[:values] })
    assert_nil Thread.current[Branchproof::Runtime::FRAME_STATE_KEY]
  ensure
    Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
    Thread.current[Branchproof::Runtime::FRAME_STATE_KEY] = nil
  end

  def test_fixture_inventory_has_no_standalone_rescue_decisions
    Dir[File.expand_path("fixtures/ruby_constructs/exc_*.rb", __dir__)].each do |path|
      inventory = ExceptionSource.new(root: File.dirname(path), limits: Branchproof::Limits.default)
                                 .inventory(paths: [path])
      rescue_decisions = inventory[:decisions].select { |entry| entry[:context] == "rescue" }
      refute_empty rescue_decisions, path
      assert(rescue_decisions.all? { |entry| entry[:support_status] == "SUPPORTED" },
             [path, rescue_decisions].inspect)
    end
  end

  def test_nonlocal_transfer_is_not_classified_as_an_unhandled_exception
    source = <<~RUBY
      def exercise(mode)
        begin
          return :returned if mode == :return
          raise IOError if mode == :raise
        rescue IOError
          raise
        end
      rescue IOError => error
        [:outer, error.class.name]
      end
    RUBY
    inventory, rewritten = instrumented(source)
    assert_empty rewritten[:diagnostics]
    inner = inventory[:decisions].find { |entry| entry[:byte_start] == source.index("begin") }
    outer = inventory[:decisions].find { |entry| entry[:id] != inner[:id] && entry[:kind] == "exception" }

    evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default,
                                         run_id: "exception-transfer-test")
    Branchproof::Runtime.boot(evidence: evidence)
    eval(rewritten[:bytes], TOPLEVEL_BINDING)
    assert_equal :returned, exercise(:return)
    assert_equal [:outer, "IOError"], exercise(:raise)

    snapshot = Branchproof::Runtime.snapshot
    refute(snapshot[:vectors].any? { |vector| vector[:decision_id] == inner[:id] && vector[:values].last == true })
    assert_equal 1, snapshot[:abort_counts][inner[:id]]
    assert(snapshot[:vectors].any? { |vector| vector[:decision_id] == outer[:id] })
  ensure
    Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
    Thread.current[Branchproof::Runtime::FRAME_STATE_KEY] = nil
  end

  def test_transfer_terminated_protected_bodies_rewrite_and_preserve_native_results
    source = <<~RUBY
      def return_value(mode)
        begin
          return (raise "argument") if mode == :raise
          return 6
        rescue StandardError
          :rescued
        end
      end

      def break_value
        [1].each do
          begin
            break :broken
          rescue StandardError
            :rescued
          end
        end
      end

      def next_value
        seen = []
        [1].each do |item|
          begin
            seen << item
            next
          rescue StandardError
            :rescued
          end
        end
        seen
      end

      def redo_source
        attempts = 0
        loop do
          begin
            attempts += 1
            break if attempts > 1
            redo
          rescue StandardError
            :rescued
          end
        end
        attempts
      end

      def multiple_return
        begin
          return 1, 2
        rescue StandardError
          :rescued
        end
      end

      def splat_next(items)
        seen = []
        items.each do |item|
          begin
            seen << item
            next *items
          rescue StandardError
            :rescued
          end
        end
        seen
      end

      def else_return(flag)
        begin
          raise "body" if flag
          :normal
        rescue StandardError
          :rescued
        else
          return :else
        end
      end

      def handler_return
        begin
          raise "body"
        rescue StandardError
          return :handler
        end
      end
    RUBY
    _inventory, rewritten = instrumented(source)

    assert rewritten[:changed], rewritten.inspect
    assert_empty rewritten[:diagnostics]
    assert_instance_of RubyVM::InstructionSequence, rewritten[:iseq]

    eval(source, TOPLEVEL_BINDING)
    native = [return_value(:ok), return_value(:raise), break_value, next_value, redo_source,
              multiple_return, splat_next([1]), else_return(false), else_return(true), handler_return]
    eval(rewritten[:bytes], TOPLEVEL_BINDING)
    instrumented = [return_value(:ok), return_value(:raise), break_value, next_value, redo_source,
                    multiple_return, splat_next([1]), else_return(false), else_return(true), handler_return]
    assert_equal native, instrumented
  end

  def test_return_argument_that_raises_does_not_record_normal_path
    source = <<~RUBY
      def exercise
        begin
          return (raise "argument")
        rescue StandardError
          :rescued
        end
      end

      def multiple_exercise
        begin
          return 1, (raise "second")
        rescue StandardError
          :rescued
        end
      end

      def splat_exercise
        begin
          return *[1, (raise "splat")]
        rescue StandardError
          :rescued
        end
      end
    RUBY
    inventory, rewritten = instrumented(source)
    assert rewritten[:changed], rewritten.inspect
    assert_empty rewritten[:diagnostics]

    evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default,
                                         run_id: "exception-transfer-argument")
    Branchproof::Runtime.boot(evidence: evidence)
    eval(rewritten[:bytes], TOPLEVEL_BINDING)
    assert_equal :rescued, exercise
    assert_equal :rescued, multiple_exercise
    assert_equal :rescued, splat_exercise
    vectors = Branchproof::Runtime.snapshot[:vectors]
    inventory[:decisions].select { |entry| entry[:kind] == "exception" }.each do |entry|
      vector = vectors.find { |candidate| candidate[:decision_id] == entry[:id] }
      assert_equal [false, true, nil], vector[:values]
    end
  ensure
    Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
    Thread.current[Branchproof::Runtime::FRAME_STATE_KEY] = nil
  end

  def test_exc_15_fixture_executes_bounded_redo_and_transfer_cases
    path = File.expand_path("fixtures/ruby_constructs/exc_15.rb", __dir__)
    inventory = Branchproof::Source.new(root: File.dirname(path), limits: Branchproof::Limits.default)
                                   .inventory(paths: [path])
    rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
    assert rewritten[:changed], rewritten.inspect
    assert_empty rewritten[:diagnostics]
    eval(File.binread(path), TOPLEVEL_BINDING)
    native = %w[return break next redo].map { |mode| example(mode) }
    eval(rewritten[:bytes], TOPLEVEL_BINDING)
    instrumented = %w[return break next redo].map { |mode| example(mode) }
    assert_equal native, instrumented
    assert_equal [:returned, :broken, [1], 2], native
  end

  def test_empty_protected_regions_record_normal_and_preserve_results
    source = <<~RUBY
      def explicit_empty
        begin
        rescue StandardError
          :rescued
        end
      end

      def implicit_empty
      rescue StandardError
        :rescued
      end

      def ensure_empty
        begin
        ensure
          :cleanup
        end
      end
    RUBY
    _inventory, rewritten = instrumented(source)
    assert rewritten[:changed], rewritten.inspect
    assert_empty rewritten[:diagnostics]
    eval(source, TOPLEVEL_BINDING)
    native = [explicit_empty, implicit_empty, ensure_empty]
    eval(rewritten[:bytes], TOPLEVEL_BINDING)
    assert_equal native, [explicit_empty, implicit_empty, ensure_empty]
    assert_equal [nil, nil, nil], native
  end

  private

  def decisions(source)
    parsed = Prism.parse(source)
    assert_empty parsed.errors
    SourceHarness.new.flow_decisions_for(parsed.value, source, "source-1")
  end

  def instrumented(source)
    directory = Dir.mktmpdir("branchproof-exception")
    path = File.join(directory, "fixture.rb")
    File.binwrite(path, source)
    inventory = ExceptionSource.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
    [inventory, ExceptionInstrumenter.new.rewrite(unit: inventory[:source_units].first)]
  end
end

# rubocop:enable Security/Eval, Style/DocumentDynamicEvalDefinition
