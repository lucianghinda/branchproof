# frozen_string_literal: true

require_relative "records" unless defined?(Branchproof::Records)

module Branchproof
  # Bridges one serial RSpec run to Runtime lifecycle ownership.
  class RSpecAdapter
    class << self
      attr_accessor :active_adapter, :runner_adapter
    end

    FORBIDDEN_OPTIONS = {
      dry_run: "dry-run",
      bisect: "bisect",
      drb: "DRb",
      runner: "custom runner"
    }.freeze

    attr_reader :tests, :late_execution_error

    def initialize(runtime:)
      @runtime = runtime
      @tests = {}
      @running = false
      @completed = false
      @completion_started = false
      @registered = false
      @current_context = nil
    end

    # rubocop:disable-next Metrics/ParameterLists
    def run(test_files:, runner_args:, on_complete:, before_load: nil, after_load: nil,
            test_selection_explicit: false)
      raise ArgumentError, "test_files must be an Array" unless test_files.is_a?(Array)
      raise ArgumentError, "runner_args must be an Array" unless runner_args.is_a?(Array)
      raise ArgumentError, "on_complete must respond to call" unless on_complete.respond_to?(:call)
      raise ArgumentError, "RSpec adapter cannot run more than once" if @running || @registered
      raise ArgumentError, "nested RSpec runs are unsupported" if self.class.active_adapter
      raise ArgumentError, "TEST_ENV_NUMBER is unsupported" if ENV.key?("TEST_ENV_NUMBER")

      require "rspec/core"
      require "rspec/core/runner"
      unless Gem::Requirement.new("~> 3.13.0").satisfied_by?(Gem::Version.new(RSpec::Core::Version::STRING))
        raise ArgumentError, "unsupported RSpec version #{RSpec::Core::Version::STRING}; use 3.13.x"
      end

      RSpec::Core::Runner.disable_autorun!
      options = RSpec::Core::ConfigurationOptions.new(runner_args)
      configured_files = Array(options.options[:files_or_directories_to_run]).map(&:to_s)
      if test_selection_explicit && configured_files.any?
        raise ArgumentError, "explicit test selection conflicts with configured RSpec selectors"
      end

      options.options[:files_or_directories_to_run] = test_files.map(&:to_s) if configured_files.empty?
      reject_options!(options)

      @running = true
      @registered = true
      @completion_callback = on_complete
      self.class.active_adapter = self
      self.class.runner_adapter = self
      install_lifecycle_hooks
      install_runner_guard
      runner = RSpec::Core::Runner.new(options)
      @native_runner = runner
      adapter = self
      runner.define_singleton_method(:setup) do |*setup_args|
        super(*setup_args)
        return if world.wants_to_quit

        adapter.validate_runner!
        after_load&.call
        adapter.send(:install_reporter_listener, configuration.reporter)
      end
      before_load&.call
      status = runner.run($stderr, $stdout)
      capture_runner_state(runner)
      complete(status: status, finalized: true)
      status
    rescue StandardError => e
      raise unless @running
      raise if @completion_started

      @run_error = e
      capture_runner_state(runner) if runner
      status = 2
      complete(status: status, finalized: false)
      status
    ensure
      if self.class.active_adapter.equal?(self)
        unattributed
        self.class.active_adapter = nil
      end
      @running = false
    end

    def validate_runner!
      return nil unless defined?(RSpec.configuration)

      configuration = RSpec.configuration
      reject_configuration!(configuration)
      if configuration.respond_to?(:parallelize) && configuration.parallelize
        raise ArgumentError,
              "parallel test scheduling is unsupported"
      end

      nil
    end

    def example_started(notification)
      example = notification.example
      record = test_record(example)
      record[:status] = "running"
      register_test(record)
    end

    def example_finished(notification)
      example = notification.example
      record = @tests[test_id(example)] || test_record(example)
      record[:name] = example.full_description.to_s
      record[:status] = status_for(example)
      register_test(record)
    end

    def reject_execution!(message)
      @run_error ||= ArgumentError.new(message)
      @late_execution_error = @run_error if @completion_started
      raise @run_error
    end

    def enter_runner!(runner)
      unless runner.equal?(@native_runner) && !@runner_entered
        reject_execution!("nested or repeated RSpec runs are unsupported")
      end
      @runner_entered = true
    end

    private

    def capture_runner_state(runner)
      @selected_test_files = runner.configuration.loaded_spec_files.map { |path| File.expand_path(path.to_s) }
      @selected_example_ids = runner.world.filtered_examples.values.flatten.map(&:id)
      @seed = runner.configuration.seed
      @non_example_failure = runner.world.non_example_failure
    end

    def reject_options!(options)
      FORBIDDEN_OPTIONS.each do |key, label|
        value = options.options[key]
        next unless value && value != false && value != []

        raise ArgumentError, "#{label} is unsupported"
      end
    end

    def reject_configuration!(configuration)
      raise ArgumentError, "dry-run is unsupported" if configuration.respond_to?(:dry_run?) && configuration.dry_run?
      raise ArgumentError, "bisect is unsupported" if configuration.respond_to?(:bisect) && configuration.bisect
      raise ArgumentError, "DRb is unsupported" if defined?(DRb) && RSpec::Core::Runner.send(:running_in_drb?)
    end

    def install_reporter_listener(reporter)
      listener = self
      reporter.register_listener(listener, :example_started, :example_finished)
    end

    def install_runner_guard
      return if RSpec::Core::Runner.singleton_class.instance_variable_defined?(:@branchproof_runner_guard)

      adapter_class = self.class
      RSpec::Core::Runner.singleton_class.prepend(Module.new do
        define_method(:run) do |*args, &block|
          adapter_class.runner_adapter&.reject_execution!("nested or repeated RSpec runs are unsupported")
          super(*args, &block)
        end
      end)
      RSpec::Core::Runner.prepend(Module.new do
        define_method(:run) do |*args, &block|
          adapter_class.runner_adapter&.enter_runner!(self)
          super(*args, &block)
        end
      end)
      RSpec::Core::Runner.singleton_class.instance_variable_set(:@branchproof_runner_guard, true)
    end

    def install_lifecycle_hooks
      return if RSpec::Core::Example.instance_variable_defined?(:@branchproof_lifecycle_hooks)

      adapter_class = self.class
      RSpec::Core::Example.prepend(Module.new do
        define_method(:run) do |*args, &block|
          adapter = adapter_class.active_adapter
          return super(*args, &block) unless adapter

          adapter.send(:begin_example, self)
          super(*args, &block)
        ensure
          adapter&.send(:end_example, self)
        end

        define_method(:run_before_example) do |*args, &block|
          adapter = adapter_class.active_adapter
          adapter&.send(:begin_attempt, self)
          result = super(*args, &block)
          adapter&.send(:phase, self, "body")
          result
        end

        define_method(:run_after_example) do |*args, &block|
          adapter = adapter_class.active_adapter
          adapter&.send(:phase, self, "teardown")
          super(*args, &block)
        end

        private :run_before_example, :run_after_example
      end)
      RSpec::Core::ExampleGroup.singleton_class.prepend(Module.new do
        define_method(:run_before_context_hooks) do |*args, &block|
          adapter = adapter_class.active_adapter
          next super(*args, &block) unless adapter

          adapter.send(:without_owner) { super(*args, &block) }
        end

        define_method(:run_after_context_hooks) do |*args, &block|
          adapter = adapter_class.active_adapter
          next super(*args, &block) unless adapter

          adapter.send(:without_owner) { super(*args, &block) }
        end
      end)
      RSpec::Core::Example.instance_variable_set(:@branchproof_lifecycle_hooks, true)
    end

    def begin_example(example)
      validate_runner!
      seen = (@seen_examples ||= {}.compare_by_identity)
      reject_execution!("repeated RSpec example attempts are unsupported") if seen[example]

      seen[example] = true
      record = test_record(example)
      record[:status] = "running"
      register_test(record)
      phase(example, "setup")
    rescue ArgumentError => e
      reject_execution!(e.message)
    end

    def begin_attempt(example)
      @attempts ||= {}
      id = test_id(example)
      if @attempts[id]
        @run_error ||= ArgumentError.new("repeated RSpec example attempts are unsupported")
        raise @run_error
      end
      @attempts[id] = true
    end

    def without_owner
      previous = @current_context
      unattributed
      yield
    ensure
      @current_context = previous
      if @runtime.respond_to?(:context)
        @runtime.context(test_id: previous&.first,
                         phase: previous&.last || "unattributed")
      end
    end

    def end_example(example)
      @tests[test_id(example)] ||= test_record(example)
      record = @tests[test_id(example)]
      record[:name] = example.full_description.to_s
      record[:status] = status_for(example)
      register_test(record)
    rescue StandardError => e
      @run_error ||= e
    ensure
      unattributed
    end

    def status_for(example)
      result = example.execution_result
      status = result.status&.to_sym
      return "failed" if (result.respond_to?(:pending_fixed?) && result.pending_fixed?) ||
                         (example.respond_to?(:pending?) && example.pending? && status == :failed)
      return "failed" if status == :failed
      return "skipped" if example.respond_to?(:skipped?) && example.skipped?
      return "skipped" if status == :pending

      status == :passed ? "passed" : "running"
    end

    def test_record(example)
      id = test_id(example)
      @tests[id] ||= {
        id: id, adapter: "rspec", name: example.full_description.to_s,
        example_id: example.id.to_s, class_name: nil, method_name: nil,
        source: source_for(example), status: "running", phase_counts: {}
      }
    end

    def test_id(example)
      Branchproof::Records.id(adapter: "rspec", example_id: example.id.to_s, source: source_for(example))
    end

    def source_for(example)
      path = example.metadata[:absolute_file_path] || example.file_path
      { path: File.expand_path(path.to_s), line: example.metadata[:line_number].to_i }
    end

    def phase(example, name)
      id = test_id(example)
      @current_context = [id, name]
      @runtime.context(test_id: id, phase: name) if @runtime.respond_to?(:context)
    end

    def unattributed
      @current_context = nil
      @runtime.context(test_id: nil, phase: "unattributed") if @runtime.respond_to?(:context)
    end

    def register_test(test)
      if @runtime.respond_to?(:register_test)
        @runtime.register_test(test: test)
      else
        evidence = @runtime.instance_variable_get(:@evidence)
        evidence.register_test(test: test) if evidence.respond_to?(:register_test)
      end
    end

    def complete(status:, finalized:)
      return if @completed || @completion_started

      @completion_started = true
      apply_canonical_phase_counts
      tests = @tests.values
      failed = tests.count { |test| test[:status] == "failed" }
      skipped = tests.count { |test| test[:status] == "skipped" }
      diagnostics = completion_diagnostics(status)
      result = {
        status: if diagnostics.any?
                  "ERROR"
                elsif tests.empty?
                  "INCOMPLETE"
                elsif failed.zero?
                  "PASSED"
                else
                  "FAILED"
                end,
        executed_tests: tests.length, failed_tests: failed, skipped_tests: skipped,
        exit_status: status.to_i, finalized: finalized && diagnostics.empty?, seed: @seed, diagnostics: diagnostics,
        selected_test_files: @selected_test_files || [], selected_example_ids: @selected_example_ids || [], tests: tests
      }
      @completion_callback.call(result)
      @completed = true
    end

    def completion_diagnostics(native_status)
      if @run_error
        code = if defined?(Branchproof::RailsSupport::Error) && @run_error.is_a?(Branchproof::RailsSupport::Error)
                 "rails_boot"
               elsif @run_error.message.match?(/unsupported|repeated|runner|dry.run/)
                 "unsupported_runner"
               else
                 "rspec_run"
               end
        return [{ code: code, severity: "error", message: "#{@run_error.class}: #{@run_error.message}" }]
      end
      if @non_example_failure || @tests.values.any? { |test| test[:status] == "running" } ||
         (native_status.to_i != 0 && @tests.values.none? { |test| test[:status] == "failed" })
        return [{ code: "rspec_run", severity: "error", message: "RSpec failed outside examples; see runner output" }]
      end

      []
    end

    def apply_canonical_phase_counts
      return unless @runtime.respond_to?(:snapshot)

      snapshot = @runtime.snapshot
      canonical = Array(snapshot[:tests] || snapshot["tests"])
      canonical_by_id = canonical.to_h do |test|
        [(test[:id] || test["id"]).to_s, test[:phase_counts] || test["phase_counts"] || {}]
      end
      @tests.each do |id, test|
        counts = canonical_by_id[id]
        test[:phase_counts] = counts unless counts.nil?
      end
    end
  end
end
