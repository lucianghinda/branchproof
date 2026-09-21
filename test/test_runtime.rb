# frozen_string_literal: true

require "test_helper"
require "branchproof/runtime"

class TestRuntime < Minitest::Test
  class Store
    attr_reader :executions

    def initialize = @executions = []

    def record(execution:)
      (@executions << execution
       { status: "recorded" })
    end
  end

  def teardown
    Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
    Thread.current[Branchproof::Runtime::FRAME_STATE_KEY] = nil
  end

  def test_condition_and_finish_return_the_original_objects_and_record_truthiness
    store = Store.new
    Branchproof::Runtime.boot(evidence: store)
    value = Object.new
    Branchproof::Runtime.enter("decision")
    assert_same value, Branchproof::Runtime.condition("decision", 0, value)
    assert_same value, Branchproof::Runtime.finish("decision", value)
    Branchproof::Runtime.leave("decision")

    execution = store.executions.fetch(0)
    assert_equal [[0, true]], execution[:observations]
    assert_equal true, execution[:outcome]
  end

  def test_frames_are_isolated_between_fibers
    store = Store.new
    Branchproof::Runtime.boot(evidence: store)
    fiber = Fiber.new do
      Branchproof::Runtime.enter("decision")
      Branchproof::Runtime.condition("decision", 0, false)
      Branchproof::Runtime.finish("decision", false)
      Branchproof::Runtime.leave("decision")
    end
    Branchproof::Runtime.enter("decision")
    Branchproof::Runtime.condition("decision", 0, true)
    fiber.resume
    Branchproof::Runtime.finish("decision", true)
    Branchproof::Runtime.leave("decision")
    assert_equal [[0, false]], store.executions.first[:observations]
    assert_equal [[0, true]], store.executions.last[:observations]
  end

  def test_context_is_captured_when_frame_enters
    store = Store.new
    Branchproof::Runtime.boot(evidence: store)
    Branchproof::Runtime.context(test_id: "test", phase: "setup")
    Branchproof::Runtime.enter("decision")
    Branchproof::Runtime.context(test_id: "other", phase: "body")
    Branchproof::Runtime.condition("decision", 0, true)
    Branchproof::Runtime.finish("decision", true)
    Branchproof::Runtime.leave("decision")
    assert_equal "test", store.executions.fetch(0)[:test_id]
    assert_equal "setup", store.executions.fetch(0)[:phase]
  end

  def test_aborted_frame_is_recorded_and_nested_frames_keep_stack_discipline
    store = Store.new
    Branchproof::Runtime.boot(evidence: store)
    Branchproof::Runtime.enter("outer")
    Branchproof::Runtime.enter("inner")
    Branchproof::Runtime.finish("inner", true)
    Branchproof::Runtime.leave("inner")
    Branchproof::Runtime.leave("outer")
    assert_equal(%w[completed aborted], store.executions.map { |execution| execution[:status] })
  end

  def test_recorder_fault_disables_storage_but_does_not_break_application
    failing = Class.new(Store) do
      def record(*)
        raise "storage failed"
      end
    end.new
    Branchproof::Runtime.boot(evidence: failing)
    value = Object.new
    Branchproof::Runtime.enter("decision")
    assert_same value, Branchproof::Runtime.condition("decision", 0, value)
    assert_same value, Branchproof::Runtime.finish("decision", value)
    Branchproof::Runtime.leave("decision")
    assert_equal "recorder_failure", Branchproof::Runtime.diagnostics.first[:code]
  end

  def test_truthiness_does_not_invoke_application_negation
    store = Store.new
    Branchproof::Runtime.boot(evidence: store)
    value = Class.new do
      attr_reader :negated

      def initialize = @negated = false
      def ! = (@negated = true)
    end.new
    Branchproof::Runtime.enter("decision")
    Branchproof::Runtime.condition("decision", 0, value)
    Branchproof::Runtime.finish("decision", value)
    Branchproof::Runtime.leave("decision")
    refute value.negated
  end

  def test_background_thread_has_an_unattributed_independent_frame
    store = Store.new
    Branchproof::Runtime.boot(evidence: store)
    Branchproof::Runtime.context(test_id: "test", phase: "body")
    thread = Thread.new do
      Branchproof::Runtime.enter("decision")
      Branchproof::Runtime.condition("decision", 0, true)
      Branchproof::Runtime.finish("decision", true)
      Branchproof::Runtime.leave("decision")
    end
    thread.join
    assert_nil store.executions.fetch(0)[:test_id]
    assert_equal "unattributed", store.executions.fetch(0)[:phase]
  end

  def test_nil_recorder_result_latches_an_error
    store = Object.new
    def store.record(*) = nil
    Branchproof::Runtime.boot(evidence: store)
    Branchproof::Runtime.enter("decision")
    Branchproof::Runtime.finish("decision", true)
    Branchproof::Runtime.leave("decision")
    assert_equal "recorder_status", Branchproof::Runtime.diagnostics.first[:code]
  end

  def test_test_metadata_uses_the_runtime_bridge
    store = Class.new do
      attr_reader :tests

      def initialize = @tests = []

      def register_test(test:)
        (@tests << test
         { status: "registered" })
      end
    end.new
    Branchproof::Runtime.boot(evidence: store)
    assert_equal "registered", Branchproof::Runtime.register_test(test: { id: "t" })[:status]
    assert_equal "t", store.tests.first[:id]
  end
end
