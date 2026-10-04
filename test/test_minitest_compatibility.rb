# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class MinitestCompatibilityTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__).freeze
  EXECUTABLE = File.join(ROOT, "exe", "branchproof").freeze
  MINITEST_VERSION = Gem.loaded_specs.fetch("minitest").version

  def test_real_consumer_matches_native_count_and_keeps_test_ids_and_lifecycle_phases
    project(source: decision_source, tests: lifecycle_tests) do |root, source_path, test_path|
      native_stdout, native_stderr, native_status = Open3.capture3(
        child_env, RbConfig.ruby, test_path, "--seed", "2468", chdir: root
      )
      result = run_branchproof(root, source_path, test_path, runner_args: ["--seed", "2468"])
      report = result.fetch(:json)
      tests = report.dig("observations", "tests")

      assert native_status.success?, native_stderr
      assert_match(/2 runs,/, native_stdout)
      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      assert_equal 2, report.dig("baseline", "executed_tests")
      assert_equal 2, native_stdout[/([0-9]+) runs,/, 1].to_i
      assert_equal 2468, report.dig("baseline", "seed")
      assert_equal %w[test_first test_second], tests.map { |test| test.fetch("method_name") }.sort
      assert_equal 2, tests.map { |test| test.fetch("id") }.uniq.length
      phases_by_test = report.dig("observations", "vectors").each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |vector, phases|
        vector.fetch("phases_by_test").each { |test_id, values| phases[test_id].concat(values) }
      end
      tests.each do |test|
        assert_equal %w[body setup teardown], test.fetch("phase_counts").keys.sort
        assert_equal %w[body setup teardown], phases_by_test.fetch(test.fetch("id")).uniq.sort
        assert_match(/\A[0-9a-f]{64}\z/, test.fetch("id"))
      end
    end
  end

  def test_name_filter_is_forwarded_and_minitest_six_include_aliases_select_tests
    project(source: decision_source, tests: filtering_tests) do |root, source_path, test_path|
      selected = run_branchproof(root, source_path, test_path, runner_args: ["--name", "/test_kept/"])
      assert_equal 0, selected.fetch(:status).exitstatus, selected.fetch(:stderr)
      assert_equal 1, selected.dig(:json, "baseline", "executed_tests")

      return if Gem::Version.new("6") > MINITEST_VERSION

      [["--include", "/test_kept/"], ["-i", "/test_kept/"]].each do |arguments|
        included = run_branchproof(root, source_path, test_path, runner_args: arguments)
        assert_equal 0, included.fetch(:status).exitstatus, "#{arguments.inspect}: #{included.fetch(:stderr)}"
        assert_equal 1, included.dig(:json, "baseline", "executed_tests"), arguments.inspect
      end
    end
  end

  def test_bisect_and_active_server_mode_are_rejected_before_test_body_runs
    ["-b", "--bisect", "--bisect=1", "--server", "--server=123"].each do |argument|
      marker = File.join(Dir.tmpdir, "branchproof-minitest-marker-#{Process.pid}-#{rand(1_000_000)}")
      result = run_marked_test(marker, runner_args: [argument])
      assert_rejected_before_body(result, marker, argument)
    ensure
      FileUtils.rm_f(marker)
    end

    marker = File.join(Dir.tmpdir, "branchproof-minitest-server-#{Process.pid}-#{rand(1_000_000)}")
    result = run_marked_test(marker, environment: { "MINITEST_SERVER" => "1" })
    assert_rejected_before_body(result, marker, "MINITEST_SERVER")
  ensure
    FileUtils.rm_f(marker) if marker
  end

  def test_minitest_six_parallel_run_order_is_rejected_before_test_body_runs
    return if Gem::Version.new("6") > MINITEST_VERSION

    marker = File.join(Dir.tmpdir, "branchproof-minitest-parallel-#{Process.pid}-#{rand(1_000_000)}")
    result = run_marked_test(marker, test_prefix: <<~RUBY)
      class ParallelOrderTest < Minitest::Test
        def self.run_order = :parallel
      end
    RUBY

    assert_rejected_before_body(result, marker, "run_order = :parallel")
  ensure
    FileUtils.rm_f(marker) if marker
  end

  def test_discovers_tests_from_the_default_test_directory
    project(source: decision_source, tests: <<~RUBY) do |root, source_path, test_path|
      class DiscoveredTest < Minitest::Test
        def test_found_by_default_pattern
          assert_equal :yes, branchproof_value(true, true)
        end
      end
    RUBY
      test_directory = File.join(root, "test")
      FileUtils.mkdir_p(test_directory)
      File.rename(test_path, File.join(test_directory, "test_discovered.rb"))
      result = run_branchproof(root, source_path, nil, discover: true)

      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      assert_equal 1, result.dig(:json, "baseline", "executed_tests")
      test_names = result.dig(:json, "observations", "tests").map { |test| test.fetch("method_name") }
      assert_equal ["test_found_by_default_pattern"], test_names
    end
  end

  def test_minitest_six_loaded_server_plugin_and_idle_executor_allow_serial_tests
    return if Gem::Version.new("6") > MINITEST_VERSION

    project(source: decision_source, tests: <<~RUBY) do |root, source_path, test_path|
      require "minitest/server_plugin"
      Minitest.parallel_executor = Object.new.tap do |executor|
        def executor.size = 1
        def executor.start = nil
        def executor.shutdown = nil
      end

      class SerialTest < Minitest::Test
        def test_serial
          assert branchproof_value(true, true)
        end
      end
    RUBY
      result = run_branchproof(root, source_path, test_path)
      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      assert_equal "PASSED", result.dig(:json, "baseline", "status")
      assert_equal 1, result.dig(:json, "baseline", "executed_tests")
    end
  end

  def test_mcdc_gate_fails_for_filtered_run_and_passes_for_full_suite
    tests = <<~RUBY
      class MCDCTest < Minitest::Test
        def test_both_true = branchproof_value(true, true)
        def test_left_false = branchproof_value(false, true)
        def test_right_false = branchproof_value(true, false)
      end
    RUBY

    project(source: decision_source, tests: tests) do |root, source_path, test_path|
      filtered = run_branchproof(root, source_path, test_path,
                                 arguments: ["--minimum", "mcdc=100"],
                                 runner_args: ["--name", "/test_both_true/"])
      complete = run_branchproof(root, source_path, test_path, arguments: ["--minimum", "mcdc=100"])

      assert_equal 1, filtered.fetch(:status).exitstatus, filtered.fetch(:stderr)
      assert_equal "PASSED", filtered.dig(:json, "baseline", "status")
      assert_equal "failed", filtered.dig(:json, "coverage_policy", "status")
      assert_equal 0, complete.fetch(:status).exitstatus, complete.fetch(:stderr)
      assert_equal "PASSED", complete.dig(:json, "baseline", "status")
      assert_equal "passed", complete.dig(:json, "coverage_policy", "status")
      assert_equal 100.0, complete.dig(:json, "analysis", "coverage", "mcdc", "percentage")
    end
  end

  private

  def decision_source
    <<~RUBY
      def branchproof_value(left, right)
        if left && right
          :yes
        else
          :no
        end
      end
    RUBY
  end

  def lifecycle_tests
    <<~RUBY
      class LifecycleTest < Minitest::Test
        def setup
          branchproof_value(true, false)
        end

        def teardown
          branchproof_value(true, false)
        end

        def test_first
          branchproof_value(true, true)
        end

        def test_second
          branchproof_value(false, true)
        end
      end
    RUBY
  end

  def filtering_tests
    <<~RUBY
      class FilterTest < Minitest::Test
        def test_kept = assert_equal :yes, branchproof_value(true, true)
        def test_removed = flunk "filtered test ran"
      end
    RUBY
  end

  def run_marked_test(marker, runner_args: [], environment: {}, test_prefix: "")
    tests = <<~RUBY
      #{test_prefix}
      class MarkerTest < Minitest::Test
        def test_marker
          File.write(#{marker.inspect}, "ran")
          assert true
        end
      end
    RUBY
    result = nil
    project(source: decision_source, tests: tests) do |root, source_path, test_path|
      result = run_branchproof(root, source_path, test_path, runner_args: runner_args, environment: environment)
    end
    result.merge(marker: marker)
  end

  def assert_rejected_before_body(result, marker, detail)
    assert_equal 2, result.fetch(:status).exitstatus, detail
    assert_equal "ERROR", result.dig(:json, "baseline", "status"), detail
    assert_includes result.dig(:json, "diagnostics").map { |diagnostic| diagnostic.fetch("code") }, "unsupported_runner"
    refute File.exist?(marker), "test body ran despite #{detail} rejection"
  end

  def project(source:, tests:)
    Dir.mktmpdir("branchproof-minitest-consumer-") do |root|
      source_path = File.join(root, "decision.rb")
      test_path = File.join(root, "decision_test.rb")
      File.write(source_path, source)
      File.write(test_path, "require #{source_path.inspect}\nrequire \"minitest/autorun\"\n#{tests}")
      yield root, source_path, test_path
    end
  end

  def run_branchproof(root, source_path, test_path, arguments: [], runner_args: [], environment: {}, discover: false)
    command = ["analyze", source_path, "--format", "json"]
    command += ["--test", test_path] unless discover
    command.concat(arguments)
    command += ["--", *runner_args] unless runner_args.empty?
    stdout, stderr, status = Open3.capture3(child_env.merge(environment), RbConfig.ruby, EXECUTABLE, *command, chdir: root)
    { stdout: stdout, stderr: stderr, status: status, json: JSON.parse(stdout) }
  rescue JSON::ParserError
    { stdout: stdout, stderr: stderr, status: status, json: nil }
  end

  def child_env
    { "MT_NO_PLUGINS" => "1" }
  end
end
