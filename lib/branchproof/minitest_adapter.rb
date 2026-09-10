# frozen_string_literal: true

module Branchproof
  # Bridges one serial Minitest run to Runtime lifecycle ownership.
  class MinitestAdapter
    class << self
      attr_accessor :active_adapter
    end

    def initialize(runtime:)
      @runtime = runtime
      @registered = false
      @tests = {}
    end

    def capabilities
      { serial: true, phases: true }.freeze
    end

    def run(test_files:, runner_args:, on_complete:, before_load: nil)
      raise ArgumentError, "test_files must be an Array" unless test_files.is_a?(Array)
      raise ArgumentError, "on_complete must respond to call" unless on_complete.respond_to?(:call)

      reject_runner_args!(runner_args)
      @runner_args = Array(runner_args).dup.freeze
      require "minitest"
      require "minitest/test"
      self.class.active_adapter = self
      install_lifecycle_hooks
      install_runner_guard
      Minitest.after_run do
        on_complete.call(baseline_result)
      rescue StandardError => e
        @completion_error = e
      ensure
        self.class.active_adapter = nil
      end
      @loading_test_files = true
      before_load&.call
      test_files.each { |path| require path }
      @registered = true
      nil
    ensure
      @loading_test_files = false
    end

    attr_reader :tests

    def validate_runner!
      runnables = defined?(Minitest::Runnable) ? Minitest::Runnable.runnables : []
      parallel = parallel_executor_active? || runnables.any? { |runnable| parallel_runnable?(runnable) }
      raise ArgumentError, "parallel test scheduling is unsupported" if parallel

      nil
    end

    private

    def install_lifecycle_hooks
      return if self.class.instance_variable_defined?(:@hooks_installed)

      Minitest::Test.prepend(Module.new do
        define_method(:run) do |*args, &block|
          adapter = Branchproof::MinitestAdapter.active_adapter
          return super(*args, &block) unless adapter

          begin
            adapter.send(:begin_test, self)
            adapter.send(:install_phase_hooks, self.class)
            super(*args, &block)
          ensure
            adapter.send(:end_test, self)
          end
        end
      end)
      self.class.instance_variable_set(:@hooks_installed, true)
    end

    def install_runner_guard
      return if Minitest.singleton_class.instance_variable_defined?(:@branchproof_runner_guard)

      Minitest.singleton_class.prepend(Module.new do
        define_method(:run) do |*args, &block|
          adapter = Branchproof::MinitestAdapter.active_adapter
          return super(*args, &block) unless adapter

          if adapter.instance_variable_get(:@loading_test_files)
            raise ArgumentError, "custom Minitest runners are unsupported"
          end
          if adapter.instance_variable_get(:@branchproof_native_run)
            raise ArgumentError, "Minitest runner invoked more than once"
          end

          adapter.instance_variable_set(:@branchproof_native_run, true)
          super(*args, &block)
        end
      end)
      Minitest.singleton_class.instance_variable_set(:@branchproof_runner_guard, true)
    end

    def parallel_executor_active?
      return false unless Minitest.respond_to?(:parallel_executor)

      executor = Minitest.parallel_executor
      return false unless executor

      rails_executor = defined?(ActiveSupport::Testing::ParallelizeExecutor) &&
                       executor.is_a?(ActiveSupport::Testing::ParallelizeExecutor)
      return false unless rails_executor

      size = executor.respond_to?(:size) ? executor.size : nil
      size.nil? || size.to_i > 1
    end

    def parallel_runnable?(runnable)
      parallel_module = defined?(Minitest::Parallel::Test) && Minitest::Parallel::Test
      return true if parallel_module && runnable.ancestors.include?(parallel_module)

      runnable.respond_to?(:test_order) && runnable.test_order == :parallel
    end

    def begin_test(test)
      test_id = test_id_for(test)
      source = begin
        test.method(test.name).source_location
      rescue StandardError
        nil
      end
      @tests[test_id] = { id: test_id, adapter: "minitest", name: test.name,
                          source: source && { path: source[0], line: source[1] }, class_name: test.class.name,
                          method_name: test.name, status: "running", phase_counts: {} }
      register_test(@tests[test_id])
      context(test_id, "setup")
    end

    def install_phase_hooks(test_class)
      return if test_class.instance_variable_defined?(:@branchproof_phase_hooks)

      adapter = self
      test_class.prepend(Module.new do
        define_method(:after_setup) do |*args, &block|
          result = super(*args, &block)
          adapter.send(:context, adapter.send(:test_id_for, self), "body")
          result
        end

        define_method(:before_teardown) do |*args, &block|
          adapter.send(:context, adapter.send(:test_id_for, self), "teardown")
          super(*args, &block)
        end
      end)
      test_class.instance_variable_set(:@branchproof_phase_hooks, true)
    end

    def end_test(test)
      test_id = test_id_for(test)
      context(nil, "unattributed")
      record = @tests[test_id]
      return unless record

      skipped = test.failures.any? do |failure|
        (failure.respond_to?(:skipped?) && failure.skipped?) ||
          (defined?(Minitest::Skip) && failure.respond_to?(:error) && failure.error.is_a?(Minitest::Skip)) ||
          failure.class.name.to_s.include?("Skip")
      end
      record[:status] = if skipped
                          "skipped"
                        else
                          (test.failures.empty? ? "passed" : "failed")
                        end
      register_test(record)
    end

    def context(test_id, phase)
      if test_id && @tests[test_id]
        counts = @tests[test_id][:phase_counts]
        counts[phase] = counts.fetch(phase, 0) + 1
      end
      return unless @runtime.respond_to?(:context)

      @runtime.context(test_id: test_id, phase: phase)
    end

    def test_id_for(test)
      return test.instance_variable_get(:@branchproof_test_id) if test.instance_variable_defined?(:@branchproof_test_id)

      source = begin
        test.method(test.name).source_location
      rescue NameError
        nil
      end
      id = if defined?(Branchproof::Records)
             Branchproof::Records.id(adapter: "minitest", class_name: test.class.name, method_name: test.name,
                                     source: source)
           else
             "minitest:#{test.class}:#{test.name}:#{source}"
           end
      test.instance_variable_set(:@branchproof_test_id, id)
      id
    end

    def register_test(test)
      if @runtime.respond_to?(:register_test)
        @runtime.register_test(test: test)
      else
        evidence = @runtime.instance_variable_get(:@evidence)
        evidence.register_test(test: test) if evidence.respond_to?(:register_test)
      end
    end

    def baseline_result
      if @completion_error
        return { status: "ERROR", executed_tests: @tests.length, failed_tests: 0, skipped_tests: 0,
                 exit_status: 2, finalized: false,
                 diagnostics: [{ code: "completion_callback", severity: "error", message: @completion_error.message }] }
      end
      tests = @tests.values
      failed = tests.count { |test| test[:status] == "failed" }
      skipped = tests.count { |test| test[:status] == "skipped" }
      {
        status: if tests.empty?
                  "INCOMPLETE"
                else
                  (failed.zero? ? "PASSED" : "FAILED")
                end,
        executed_tests: tests.length, failed_tests: failed, skipped_tests: skipped,
        seed: seed_value, exit_status: failed.zero? ? 0 : 1,
        finalized: true, tests: tests
      }
    end

    def seed_value
      index = @runner_args.index("--seed")
      if index && @runner_args[index + 1]
        @runner_args[index + 1].to_i
      else
        (Minitest.respond_to?(:seed) ? Minitest.seed : nil)
      end
    end

    def reject_runner_args!(args)
      forbidden = Array(args).select do |arg|
        %w[--parallel --parallelize --fork --processes
           --runner].include?(arg.to_s) || arg.to_s.start_with?("--parallel=", "--fork=", "--processes=")
      end
      raise ArgumentError, "parallel, forked, and custom runners are unsupported" unless forbidden.empty?
    end
  end
end
