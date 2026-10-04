# frozen_string_literal: true

require "test_helper"
require "branchproof/minitest_adapter"

class TestMinitestAdapter < Minitest::Test
  RuntimeSpy = Struct.new(:contexts) do
    def context(test_id:, phase:) = contexts << [test_id, phase]
  end

  def test_parallel_runner_tokens_are_rejected
    adapter = Branchproof::MinitestAdapter.new(runtime: RuntimeSpy.new([]))
    error = assert_raises(ArgumentError) do
      adapter.run(test_files: [], runner_args: ["--parallel"], on_complete: ->(_result) {})
    end
    assert_includes error.message, "unsupported"
  end

  def test_run_accepts_minitest_6_before_application_boot
    with_minitest_version("6.0.0") do
      adapter = Branchproof::MinitestAdapter.new(runtime: RuntimeSpy.new([]))
      before_load_called = false
      adapter.run(test_files: [], runner_args: [], on_complete: ->(_result) {},
                  before_load: -> { before_load_called = true })

      assert before_load_called
      assert_same adapter, Branchproof::MinitestAdapter.active_adapter
    end
  end

  def test_minitest_six_run_order_parallel_marker_is_rejected
    adapter = Branchproof::MinitestAdapter.new(runtime: RuntimeSpy.new([]))
    parallel_test = Class.new(Minitest::Test) do
      def self.run_order = :parallel
    end

    error = assert_raises(ArgumentError) { adapter.validate_runner! }
    assert_includes error.message, "parallel test scheduling"
  ensure
    Minitest::Runnable.runnables.delete(parallel_test) if parallel_test
  end

  def test_bisect_and_server_runner_options_are_rejected
    adapter = Branchproof::MinitestAdapter.new(runtime: RuntimeSpy.new([]))
    %w[-b --bisect --bisect=1 --server --server=123].each do |argument|
      error = assert_raises(ArgumentError) do
        adapter.run(test_files: [], runner_args: [argument], on_complete: ->(_result) {})
      end
      assert_includes error.message, "unsupported"
    end
  end

  def test_active_minitest_server_integration_is_rejected
    adapter = Branchproof::MinitestAdapter.new(runtime: RuntimeSpy.new([]))
    previous_server = Minitest.instance_variable_get(:@server)
    Minitest.instance_variable_set(:@server, 123)
    error = assert_raises(ArgumentError) { adapter.validate_runner! }
    assert_includes error.message, "server"
  ensure
    Minitest.instance_variable_set(:@server, previous_server)
  end

  def test_minitest_server_environment_switch_is_rejected
    adapter = Branchproof::MinitestAdapter.new(runtime: RuntimeSpy.new([]))
    previous_server_env = ENV.fetch("MINITEST_SERVER", nil)
    ENV["MINITEST_SERVER"] = "1"

    error = assert_raises(ArgumentError) { adapter.validate_runner! }
    assert_includes error.message, "server"
  ensure
    previous_server_env ? ENV["MINITEST_SERVER"] = previous_server_env : ENV.delete("MINITEST_SERVER")
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

  def test_minitest_6_serial_suite_without_parallel_executor_is_allowed
    adapter = Branchproof::MinitestAdapter.new(runtime: RuntimeSpy.new([]))
    serial_test = Class.new(Minitest::Test) do
      def self.run_order = :alpha
    end

    assert_nil adapter.validate_runner!
  ensure
    Minitest::Runnable.runnables.delete(serial_test) if serial_test
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

  private

  def with_minitest_version(version)
    specs = Gem.loaded_specs
    original_spec = specs["minitest"]
    specs["minitest"] = Gem::Specification.new("minitest", version)
    had_version = Minitest.const_defined?(:VERSION, false)
    original_version = Minitest.const_get(:VERSION, false) if had_version
    Minitest.send(:remove_const, :VERSION) if had_version
    Minitest.const_set(:VERSION, version)
    yield
  ensure
    Minitest.send(:remove_const, :VERSION) if Minitest.const_defined?(:VERSION, false)
    Minitest.const_set(:VERSION, original_version) if had_version
    specs.delete("minitest")
    specs["minitest"] = original_spec if original_spec
  end
end
