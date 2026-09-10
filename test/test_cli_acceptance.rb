# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class CLIAcceptanceTest < Minitest::Test
  GEM_ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.join(GEM_ROOT, "exe", "mcdc")

  def test_failed_assertion_is_a_failed_run_with_exit_one
    result = run_project(source: decision_source, test_source: <<~RUBY)
      class FailureTest < Minitest::Test
        def test_assertion
          assert_equal 1, 2
        end
      end
    RUBY

    assert_equal 1, result[:status].exitstatus, result[:stderr]
    assert_equal "FAILED", result.fetch(:json).dig("baseline", "status")
    assert_equal 1, result.fetch(:json).dig("baseline", "failed_tests")
  end

  def test_application_exception_is_a_failed_run_with_exit_one
    result = run_project(source: decision_source, test_source: <<~RUBY)
      class ExceptionTest < Minitest::Test
        def test_exception
          raise "application exploded"
        end
      end
    RUBY

    assert_equal 1, result[:status].exitstatus, result[:stderr]
    assert_equal "FAILED", result.fetch(:json).dig("baseline", "status")
    assert_equal 1, result.fetch(:json).dig("baseline", "failed_tests")
  end

  def test_empty_selection_and_empty_suite_exit_two
    result = run_project(source: decision_source, test_source: "")

    assert_equal 2, result[:status].exitstatus, result[:stderr]
    assert_equal "INCOMPLETE", result.fetch(:json).dig("baseline", "status")
    assert_equal 0, result.fetch(:json).dig("baseline", "executed_tests")
  end

  def test_skips_are_counted_in_the_baseline
    result = run_project(source: decision_source, test_source: <<~RUBY)
      class SkipTest < Minitest::Test
        def test_skipped
          skip "waiting for dependency"
        end
      end
    RUBY

    json = result.fetch(:json)
    assert_equal 0, result[:status].exitstatus, result[:stderr]
    assert_equal 1, json.dig("baseline", "skipped_tests")
    assert_equal 0, json.dig("baseline", "failed_tests")
  end

  def test_parallelize_me_is_rejected_before_the_suite_runs
    marker = "#{Dir.tmpdir}/branchproof-parallel-#{Process.pid}-#{rand(1_000_000)}"
    result = run_project(source: decision_source, test_source: <<~RUBY, extra_files: { "marker.path" => marker })
      class ParallelTest < Minitest::Test
        parallelize_me!

        def test_never_runs
          File.write(#{marker.inspect}, "ran")
        end
      end
    RUBY

    assert_equal 2, result[:status].exitstatus
    assert_equal "ERROR", result.fetch(:json).dig("baseline", "status")
    assert_includes result.fetch(:json)["diagnostics"].map { |item| item["code"] }, "unsupported_runner"
    refute File.exist?(marker), "parallel test body ran despite rejection"
  ensure
    FileUtils.rm_f(marker)
  end

  def test_explicit_minitest_run_is_rejected_without_double_execution
    marker = "#{Dir.tmpdir}/branchproof-custom-#{Process.pid}-#{rand(1_000_000)}"
    result = run_project(source: decision_source, test_source: <<~RUBY, extra_files: { "marker.path" => marker })
      class CustomRunnerTest < Minitest::Test
        def test_never_runs
          File.write(#{marker.inspect}, "ran")
        end
      end

      Minitest.run
    RUBY

    assert_equal 2, result[:status].exitstatus
    assert_equal "ERROR", result.fetch(:json).dig("baseline", "status")
    refute File.exist?(marker), "custom runner test body ran"
  ensure
    FileUtils.rm_f(marker)
  end

  def test_comment_and_string_containing_minitest_run_are_not_custom_runners
    result = run_project(source: decision_source, test_source: <<~RUBY)
      # Minitest.run is only documentation here.
      class FalsePositiveRunnerTest < Minitest::Test
        RUNNER_NAME = "Minitest.run"

        def test_passes
          assert_equal "Minitest.run", RUNNER_NAME
        end
      end
    RUBY

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    assert_equal "PASSED", result.fetch(:json).dig("baseline", "status")
  end

  def test_after_run_exception_cannot_produce_success
    result = run_project(source: decision_source, test_source: <<~RUBY)
      class AfterRunFailureTest < Minitest::Test
        def test_passes
          assert true
        end
      end

      Minitest.after_run { raise "late application failure" }
    RUBY

    assert_equal 2, result[:status].exitstatus, result[:stderr]
    refute_equal "PASSED", result.fetch(:json).dig("baseline", "status")
    assert_operator result.fetch(:json).fetch("diagnostics").length, :>, 0
  end

  def test_application_output_does_not_pollute_json_stdout
    result = run_project(source: decision_source, test_source: <<~RUBY)
      class OutputTest < Minitest::Test
        def test_output
          puts "application stdout"
          warn "application stderr"
          assert true
        end
      end
    RUBY

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    assert_equal "PASSED", result.fetch(:json).dig("baseline", "status")
    refute_includes result[:stdout], "application stdout"
  end

  def test_seed_and_name_are_forwarded_as_exact_runner_tokens
    result = run_project(source: decision_source, test_source: <<~RUBY,
      class FilterTest < Minitest::Test
        def test_selected
          assert true
        end

        def test_not_selected
          raise "wrong test selected"
        end
      end
    RUBY
                         runner_args: ["--seed", "1234", "--name", "/test_selected/"])

    json = result.fetch(:json)
    assert_equal 0, result[:status].exitstatus, result[:stderr]
    assert_equal 1, json.dig("baseline", "executed_tests")
    assert_equal 1234, json.dig("baseline", "seed")
  end

  def test_output_file_is_complete_json_and_uses_atomic_replacement
    result = run_project(source: decision_source, test_source: passing_test_source, output: "report.json")
    assert_equal 0, result[:status].exitstatus, result[:stderr]
    document = result.fetch(:output_json)
    assert_equal "PASSED", document.dig("baseline", "status")
    assert_empty result.fetch(:output_tmp_files)
  end

  def test_invalid_missing_and_unknown_options_are_usage_errors
    cases = [
      ["--level", "4"],
      ["--format", "yaml"],
      ["--output"],
      ["--limits", "missing-limits.json"],
      ["--unknown"]
    ]
    cases.each do |args|
      result = run_project(source: decision_source, test_source: passing_test_source, args: args)
      assert_equal 2, result[:status].exitstatus, "#{args.inspect}: #{result[:stderr]}"
      assert_empty result[:stdout], args.inspect
      refute_empty result[:stderr], args.inspect
    end
  end

  def test_levels_one_two_and_three_run_the_tests_once_each
    [1, 2, 3].each do |level|
      counter = "#{Dir.tmpdir}/branchproof-counter-#{Process.pid}-#{level}-#{rand(1_000_000)}"
      result = run_project(source: decision_source, test_source: <<~RUBY, extra_files: { "counter.path" => counter }, args: ["--level", level.to_s])
        class OneRunTest < Minitest::Test
          def test_once
            File.open(#{counter.inspect}, "a") { |file| file.puts "run" }
            assert true
          end
        end
      RUBY

      assert_equal 0, result[:status].exitstatus, "level #{level}: #{result[:stderr]}"
      assert_equal 1, File.readlines(counter).length, "level #{level} reran the test suite"
    ensure
      FileUtils.rm_f(counter)
    end
  end

  def test_metrics_distinguish_supported_unexecuted_and_unsupported_conditions
    source = <<~RUBY
      def never_called
        if true && false
          :supported
        end
      end
      if (true and false)
        :unsupported
      end
    RUBY
    result = run_project(source: source,
                         test_source: "class PassingTest < Minitest::Test\n  def test_passes\n    assert true\n  end\nend\n")
    assert_kind_of Hash, result[:json], result[:stderr]
    metrics = result.fetch(:json).fetch("metrics")

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    assert_equal 2, metrics.fetch("discovered")
    assert_equal 1, metrics.fetch("supported")
    assert_equal 1, metrics.fetch("unsupported")
    assert_equal 1, metrics.fetch("unexecuted")
    assert_equal 2, metrics.fetch("eligible_conditions")
    assert_equal metrics.fetch("discovered"), metrics.fetch("supported") + metrics.fetch("unsupported")
  end

  def test_utf8_and_non_utf8_sources_have_valid_json_reports
    utf8 = run_project(source: "# café\nif true\n  :ok\nend\n",
                       test_source: "class PassingTest < Minitest::Test\n  def test_passes\n    assert true\n  end\nend\n")
    latin1 = "# encoding: ISO-8859-1\n# caf\xE9\nif true\n  :ok\nend\n".b
    non_utf8 = run_project(source: latin1,
                           test_source: "class PassingTest < Minitest::Test\n  def test_passes\n    assert true\n  end\nend\n")

    [utf8, non_utf8].each do |result|
      assert_equal 0, result[:status].exitstatus, result[:stderr]
      assert_kind_of Hash, result.fetch(:json)
      assert_operator result.fetch(:json).fetch("source_inventory").fetch("source_units").length, :>, 0
    end
  end

  def test_lifecycle_probes_preserve_setup_body_teardown_phases_and_failures
    result = run_project(source: decision_source, test_source: <<~RUBY)
      class LifecycleTest < Minitest::Test
        def setup
          File.open(ENV.fetch("BRANCHPROOF_PHASE_LOG"), "a") { |file| file.puts "setup-before" }
          branchproof_value(true)
          super
          branchproof_value(true)
          File.open(ENV.fetch("BRANCHPROOF_PHASE_LOG"), "a") { |file| file.puts "setup-after" }
        end

        def teardown
          File.open(ENV.fetch("BRANCHPROOF_PHASE_LOG"), "a") { |file| file.puts "teardown-before" }
          branchproof_value(true)
          super
          branchproof_value(true)
          File.open(ENV.fetch("BRANCHPROOF_PHASE_LOG"), "a") { |file| file.puts "teardown-after" }
        end

        def test_lifecycle
          branchproof_value(true)
          assert true
        end
      end
    RUBY

    assert_kind_of Hash, result[:json], result[:stderr]
    phases = result.fetch(:json).dig("observations", "tests").flat_map { |test| test.fetch("phase_counts").keys }
    assert_equal 0, result[:status].exitstatus, result[:stderr]
    assert_includes phases, "setup"
    assert_includes phases, "body"
    assert_includes phases, "teardown"
    vectors = result.fetch(:json).dig("observations", "vectors")
    assert_operator vectors.length, :>, 0
    assert(vectors.any? { |vector| vector.fetch("phases_by_test").values.flatten.include?("setup") })
    assert(vectors.any? { |vector| vector.fetch("phases_by_test").values.flatten.include?("body") })
    assert(vectors.any? { |vector| vector.fetch("phases_by_test").values.flatten.include?("teardown") })
  end

  def test_setup_and_teardown_failures_are_reported_as_failed_tests
    result = run_project(source: decision_source, test_source: <<~RUBY)
      class SetupFailureTest < Minitest::Test
        def setup
          raise "setup broke"
        end

        def test_setup_failure
          flunk "body should not be reached"
        end
      end

      class TeardownFailureTest < Minitest::Test
        def test_teardown_failure
          assert true
        end

        def teardown
          raise "teardown broke"
        end
      end
    RUBY

    assert_equal 1, result[:status].exitstatus, result[:stderr]
    assert_equal "FAILED", result.fetch(:json).dig("baseline", "status")
    assert_equal 2, result.fetch(:json).dig("baseline", "failed_tests")
  end

  def test_core_can_analyze_adapter_neutral_ownership_without_loading_minitest
    Dir.mktmpdir("branchproof-core-acceptance-") do |root|
      source_path = File.join(root, "decision.rb")
      File.write(source_path, "if true && false\n  :ok\nend\n")
      script = <<~RUBY
        require "json"
        require "branchproof"
        abort "Minitest was loaded" if defined?(Minitest)
        inventory = Branchproof::Source.new(root: #{root.inspect}, limits: Branchproof::Limits.default).inventory(paths: [#{source_path.inspect}])
        evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default, run_id: "core-run")
        decision = inventory.fetch(:decisions).first
        test_id = "adapter-neutral-test"
        evidence.register_test(test: {id: test_id, adapter: "fake", name: "fake#test", phase_counts: {}})
        evidence.record(execution: {run_id: "core-run", execution_id: "execution-1", decision_id: decision.fetch(:id),
          test_id: test_id, phase: "body", owner: {adapter: "fake", test_id: test_id}, observations: [[0, true], [1, false]],
          outcome: false, status: "completed"})
        analysis = Branchproof::Analyzer.new(inventory: inventory, evidence: evidence.snapshot, limits: Branchproof::Limits.default).call
        puts JSON.generate(status: "ok", proven_count: analysis.fetch(:proven_count), minitest: defined?(Minitest))
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I",
                                              File.join(GEM_ROOT, "lib"), "-e", script)
      assert status.success?, stderr
      document = JSON.parse(stdout)
      assert_equal "ok", document.fetch("status")
      assert_nil document.fetch("minitest")
    end
  end

  private

  def decision_source
    <<~RUBY
      def branchproof_value(value)
        if value && value != :never
          :yes
        else
          :no
        end
      end
    RUBY
  end

  def passing_test_source
    <<~RUBY
      class PassingTest < Minitest::Test
        def test_passes
          assert_equal :yes, branchproof_value(true)
        end
      end
    RUBY
  end

  def run_project(source:, test_source:, args: [], runner_args: [], output: nil, extra_files: {})
    Dir.mktmpdir("branchproof-cli-acceptance-") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      File.binwrite(File.join(root, "lib", "decision.rb"), source)
      File.binwrite(File.join(root, "test", "decision_test.rb"),
                    "require #{File.join(root, "lib", "decision.rb").inspect}\nrequire \"minitest/autorun\"\n#{test_source}")
      extra_files.each { |name, content| File.binwrite(File.join(root, name), content) unless name == "marker.path" }
      phase_log = File.join(root, "phase.log")
      env = { "MT_NO_PLUGINS" => "1", "BRANCHPROOF_PHASE_LOG" => phase_log }
      cli_args = ["analyze", File.join(root, "lib", "decision.rb"), "--format", "json", "--test",
                  File.join(root, "test", "decision_test.rb"), *args]
      cli_args += ["--output", File.join(root, output)] if output
      cli_args += ["--", *runner_args] unless runner_args.empty?
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, EXECUTABLE, *cli_args, chdir: root)
      parsed = begin
        JSON.parse(stdout)
      rescue JSON::ParserError
        nil
      end
      output_path = output && File.join(root, output)
      output_json = output_path && File.file?(output_path) ? JSON.parse(File.binread(output_path)) : nil
      output_tmp_files = output_path ? Dir["#{output_path}.tmp-*"] : []
      { root: root, stdout: stdout, stderr: stderr, status: status, json: parsed,
        output_json: output_json, output_tmp_files: output_tmp_files }
    end
  end
end
