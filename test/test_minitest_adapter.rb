# frozen_string_literal: true

require "test_helper"
require "branchproof/minitest_adapter"

class TestMinitestAdapter < Minitest::Test
  RuntimeSpy = Struct.new(:contexts) do
    def context(test_id:, phase:) = contexts << [test_id, phase]
  end

  def test_capabilities_declare_serial_phases
    capabilities = Branchproof::MinitestAdapter.new(runtime: RuntimeSpy.new([])).capabilities
    assert_equal({ serial: true, phases: true }, capabilities)
    assert_predicate capabilities, :frozen?
  end

  def test_parallel_runner_tokens_are_rejected
    adapter = Branchproof::MinitestAdapter.new(runtime: RuntimeSpy.new([]))
    error = assert_raises(ArgumentError) do
      adapter.run(test_files: [], runner_args: ["--parallel"], on_complete: ->(_result) {})
    end
    assert_includes error.message, "unsupported"
  end

  def test_before_load_runs_after_guards_are_installed
    adapter = Branchproof::MinitestAdapter.new(runtime: RuntimeSpy.new([]))
    events = []

    adapter.run(test_files: [], runner_args: [], on_complete: ->(_result) {}, before_load: lambda {
      events << :before_load
      assert(Minitest::Test.ancestors.any? do |ancestor|
        ancestor.method_defined?(:run, false)
      end)
      assert_equal adapter, Branchproof::MinitestAdapter.active_adapter
    })

    assert_equal [:before_load], events
    assert_equal false, adapter.instance_variable_get(:@loading_test_files)
  end

  def test_serial_minitest_run_is_allowed_and_parallel_marker_is_rejected
    adapter = Branchproof::MinitestAdapter.new(runtime: RuntimeSpy.new([]))
    assert_nil adapter.validate_runner!

    parallel_test = Class.new(Minitest::Test) do
      def self.test_order = :parallel
    end
    error = assert_raises(ArgumentError) { adapter.validate_runner! }
    assert_includes error.message, "parallel test scheduling"
  ensure
    Minitest::Runnable.runnables.delete(parallel_test) if parallel_test
  end

  def test_completion_callback_errors_are_reported_as_error
    adapter = Branchproof::MinitestAdapter.new(runtime: RuntimeSpy.new([]))
    initial_callbacks = Minitest.class_variable_get(:@@after_run).length

    adapter.run(test_files: [], runner_args: [], on_complete: ->(_value) { raise "completion exploded" })
    callback = Minitest.class_variable_get(:@@after_run)[initial_callbacks]
    callback.call
    result = adapter.send(:baseline_result)

    assert_equal "ERROR", result[:status]
    assert_equal false, result[:finalized]
    assert_equal "completion_callback", result[:diagnostics].first[:code]
  end
end
