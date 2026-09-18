# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "branchproof/rspec_adapter"

class TestRSpecAdapter < Minitest::Test
  def test_runs_specs_synchronously_and_reports_examples
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "sample_spec.rb")
      File.write(spec, <<~RUBY)
        RSpec.describe "math" do
          it("passes") { expect(1 + 1).to eq(2) }
          it("skips") { skip "later" }
        end
      RUBY
      result = run_child(spec)

      assert_equal 0, result.fetch("status_code")
      assert_equal 1, result.fetch("completion_count")
      assert_equal %w[passed skipped].sort, result.fetch("tests").map { |test| test.fetch("status") }.sort
      assert(result.fetch("tests").all? { |test| test.fetch("adapter") == "rspec" })
    end
  end

  def test_registers_each_example_only_at_reporter_start_and_finish_without_snapshot
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "sample_spec.rb")
      File.write(spec, 'RSpec.describe { it("works") { expect(true).to be(true) } }')
      result = run_child(spec)
      assert_equal 2, result.fetch("registrations")
      assert_equal 0, result.fetch("snapshots")
    end
  end

  def test_reports_failed_and_pending_fixed_statuses
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "sample_spec.rb")
      File.write(spec, <<~RUBY)
        RSpec.describe "math" do
          it("fails") { expect(1).to eq(2) }
          it("fixed", :pending) { expect(1).to eq(1) }
        end
      RUBY
      result = run_child(spec)

      assert_equal 1, result.fetch("status_code")
      assert_equal %w[failed failed].sort, result.fetch("tests").map { |test| test.fetch("status") }.sort
    end
  end

  def test_suite_hook_error_is_error_even_when_failure_exit_code_is_zero
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "sample_spec.rb")
      File.write(spec, <<~RUBY)
        RSpec.configure { |config| config.failure_exit_code = 0 }
        RSpec.configure { |config| config.before(:suite) { raise "suite exploded" } }
        RSpec.describe { it { expect(true).to be(true) } }
      RUBY
      result = run_child(spec)

      assert_equal 0, result.fetch("status_code")
      assert_equal "ERROR", result.fetch("completion_status")
    end
  end

  def test_rejects_effective_unsupported_options
    adapter = Branchproof::RSpecAdapter.new(runtime: Object.new)
    error = assert_raises(ArgumentError) do
      adapter.run(test_files: [], runner_args: ["--dry-run"], on_complete: ->(_result) {})
    end
    assert_includes error.message, "dry-run"
  end

  def test_completion_callback_errors_propagate
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "sample_spec.rb")
      File.write(spec, "RSpec.describe { it { expect(true).to be(true) } }\n")
      result = run_callback_error_child(spec, dir)

      assert_equal "RuntimeError", result.fetch("error_class")
      assert_equal "callback exploded", result.fetch("error")
    end
  end

  def test_completion_is_called_once
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "sample_spec.rb")
      File.write(spec, "RSpec.describe { it { expect(true).to be(true) } }\n")
      result = run_child(spec)

      assert_equal 1, result.fetch("completion_count")
      assert_equal 1, result.fetch("tests").length
    end
  end

  def test_project_options_file_selector_uses_native_rspec_parsing
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "sample_spec.rb")
      File.write(spec, <<~RUBY)
        RSpec.describe "group with spaces" do
          it("selected example") { expect(true).to be(true) }
          it("filtered example") { raise "must not run" }
        end
      RUBY
      File.write(File.join(dir, ".rspec"), "--example \"selected example\"\n")
      result = run_child(spec, chdir: dir)

      assert_equal 1, result.fetch("completion_count")
      assert_equal(["group with spaces selected example"], result.fetch("tests").map { |test| test.fetch("name") })
    end
  end

  def test_spec_opts_selector_preserves_spaces
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "sample_spec.rb")
      File.write(spec, <<~RUBY)
        RSpec.describe "group with spaces" do
          it("selected example") { expect(true).to be(true) }
          it("filtered example") { raise "must not run" }
        end
      RUBY
      result = run_child(spec, chdir: dir, env: { "SPEC_OPTS" => "--example 'selected example'" })

      assert_equal(["group with spaces selected example"], result.fetch("tests").map { |test| test.fetch("name") })
    end
  end

  def test_requiring_rspec_autorun_does_not_duplicate_the_run
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "autorun_spec.rb")
      File.write(spec, "require \"rspec/autorun\"\nRSpec.describe { it { expect(true).to be(true) } }\n")
      result = run_child(spec, chdir: dir)

      assert_equal 1, result.fetch("completion_count")
      assert_equal 1, result.fetch("tests").length
    end
  end

  def test_shared_examples_included_twice_keep_distinct_native_ids
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "shared_spec.rb")
      File.write(spec, <<~RUBY)
        RSpec.shared_examples "shared behavior" do
          it("does the thing") { expect(true).to be(true) }
          it("does another thing") { expect(true).to be(true) }
        end
        RSpec.describe "first" do
          include_examples "shared behavior"
        end
        RSpec.describe "second" do
          include_examples "shared behavior"
        end
      RUBY
      result = run_child(spec)

      tests = result.fetch("tests")
      assert_equal 4, tests.length
      assert_equal 4, tests.map { |test| test.fetch("id") }.uniq.length
      assert_equal 4, tests.map { |test| test.fetch("example_id") }.uniq.length
      assert(tests.all? { |test| test.dig("source", "path") == File.expand_path(spec) })
      assert(tests.all? { |test| test.fetch("class_name").nil? && test.fetch("method_name").nil? })
    end
  end

  def test_around_hooks_that_do_not_yield_or_raise_do_not_leak_context
    cases = {
      "never-yields" => "around { |_example| }",
      "before-fails" => 'around { |_example| raise "before around" }',
      "after-fails" => 'around { |example| example.run; raise "after around" }'
    }
    cases.each do |name, hook|
      Dir.mktmpdir do |dir|
        spec = File.join(dir, "around_spec.rb")
        File.write(spec, <<~RUBY)
          RSpec.describe "#{name}" do
            #{hook}
            it("wrapped") { expect(true).to be(true) }
            context "following" do
              it("passes") { expect(true).to be(true) }
            end
          end
        RUBY
        result = run_child(spec)
        tests = result.fetch("tests")
        assert_equal 2, tests.length, name
        assert_equal ["#{name} wrapped", "#{name} following passes"], tests.map { |test| test.fetch("name") }, name
        assert tests.all? { |test| test.fetch("status") != "running" }, name
      end
    end
  end

  def test_effective_options_are_rejected_before_helpers_load
    options = {
      "project dry-run" => { file: ".rspec-local", contents: "--dry-run\n", env: {} },
      "custom dry-run" => { file: "custom.options", contents: "--dry-run\n", env: {}, args: ["--options", "custom.options"] },
      "SPEC_OPTS dry-run" => { file: nil, contents: nil, env: { "SPEC_OPTS" => "--dry-run" } },
      "bisect" => { file: nil, contents: nil, env: {}, args: ["--bisect"] },
      "DRb" => { file: nil, contents: nil, env: {}, args: ["--drb"] }
    }
    options.each do |name, option|
      Dir.mktmpdir do |dir|
        spec = File.join(dir, "guard_spec.rb")
        marker = File.join(dir, "loaded")
        File.write(spec, "File.write(#{marker.inspect}, 'loaded')\nRSpec.describe { it { expect(true).to be(true) } }\n")
        File.write(File.join(dir, option.fetch(:file)), option.fetch(:contents)) if option[:file]
        result = run_guard_child(spec, dir: dir, env: option.fetch(:env), runner_args: Array(option[:args]))

        assert_equal "Branchproof::RSpecAdapter::UnsupportedRunner", result.fetch("error_class"), name
        assert_match(/unsupported|DRb|bisect|dry-run/i, result.fetch("error"), name)
        refute File.exist?(marker), name
      end
    end
  end

  def test_unrelated_error_words_do_not_classify_an_error_as_unsupported_runner
    adapter = Branchproof::RSpecAdapter.new(runtime: Object.new)
    adapter.instance_variable_set(:@run_error, RuntimeError.new("unsupported account in custom runner data"))
    diagnostics = adapter.send(:completion_diagnostics, 2)
    assert_equal "rspec_run", diagnostics.first.fetch(:code)
  end

  private

  def run_child(spec, expected_status: 0, chdir: nil, env: {})
    script = File.join(Dir.tmpdir, "branchproof_rspec_adapter_test_#{Process.pid}.rb")
    lib = File.expand_path("../lib", __dir__)
    File.write(script, <<~RUBY)
      $LOAD_PATH.unshift #{lib.inspect}
      require "json"
      require "branchproof/rspec_adapter"
      runtime = Object.new
      def runtime.context(test_id:, phase:); end
      def runtime.register_test(test:); @registrations = (@registrations || 0) + 1; end
      def runtime.snapshot; @snapshots = (@snapshots || 0) + 1; {}; end
      def runtime.test_phase_counts; {}; end
      adapter = Branchproof::RSpecAdapter.new(runtime: runtime)
      completed = []
      status = adapter.run(test_files: [#{spec.inspect}], runner_args: ["--format", "progress"], test_selection_explicit: true,
                           on_complete: ->(result) { completed << result })
      puts JSON.generate(status_code: status, completion_count: completed.length,
                         completion_status: completed.first && completed.first[:status],
                         tests: adapter.tests.values, registrations: runtime.instance_variable_get(:@registrations),
                         snapshots: runtime.instance_variable_get(:@snapshots) || 0)
    RUBY
    output, error, status = Open3.capture3(env, RbConfig.ruby, script, chdir: chdir || Dir.pwd)
    assert_equal expected_status, status.exitstatus, error
    JSON.parse(output.lines.last)
  ensure
    FileUtils.rm_f(script)
  end

  def run_guard_child(spec, dir:, env:, runner_args:)
    script = File.join(Dir.tmpdir, "branchproof_rspec_guard_#{Process.pid}.rb")
    lib = File.expand_path("../lib", __dir__)
    File.write(script, <<~RUBY)
      $LOAD_PATH.unshift #{lib.inspect}
      require "json"
      require "branchproof/rspec_adapter"
      adapter = Branchproof::RSpecAdapter.new(runtime: Object.new)
      begin
        adapter.run(test_files: [#{spec.inspect}], runner_args: #{runner_args.inspect}, on_complete: ->(_result) {})
      rescue => error
        puts JSON.generate(error_class: error.class.name, error: error.message)
      end
    RUBY
    output, error, status = Open3.capture3(env, RbConfig.ruby, script, chdir: dir)
    assert_predicate status, :success?, error
    JSON.parse(output.lines.last)
  ensure
    FileUtils.rm_f(script)
  end

  def run_callback_error_child(spec, dir)
    script = File.join(Dir.tmpdir, "branchproof_rspec_callback_#{Process.pid}.rb")
    lib = File.expand_path("../lib", __dir__)
    File.write(script, <<~RUBY)
      $LOAD_PATH.unshift #{lib.inspect}
      require "json"
      require "branchproof/rspec_adapter"
      runtime = Object.new
      def runtime.context(test_id:, phase:); end
      def runtime.register_test(test:); end
      def runtime.test_phase_counts; {}; end
      adapter = Branchproof::RSpecAdapter.new(runtime: runtime)
      begin
        adapter.run(test_files: [#{spec.inspect}], runner_args: [], test_selection_explicit: true,
                    on_complete: ->(_result) { raise "callback exploded" })
      rescue => error
        puts JSON.generate(error_class: error.class.name, error: error.message)
      end
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, script, chdir: dir)
    assert_predicate status, :success?, error
    JSON.parse(output.lines.last)
  ensure
    FileUtils.rm_f(script)
  end
end
