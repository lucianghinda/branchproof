# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "support/rspec_constructs"

class TestRSpecAcceptance < Minitest::Test
  EXECUTABLE = RSpecConstructs::EXECUTABLE

  def test_cli_runs_rspec_once_and_preserves_lifecycle_and_saved_report
    with_project do |root|
      write_rspec_project(root, <<~RUBY)
        RSpec.describe "Access" do
          before { branchproof_value(true) }
          after { branchproof_value(false) }

          it("allows admins") do
            expect(branchproof_value(true)).to eq(:yes)
            expect(branchproof_value(false)).to eq(:no)
          end
        end
      RUBY
      result = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--format", "json",
                              "--test", "spec/access_spec.rb", "--level", "3", "--output", "report.json",
                              "--", "--seed", "2468"])
      report = result.fetch(:output_json)
      assert result.fetch(:status).success?, result.fetch(:stderr)
      assert_equal "PASSED", report.dig("baseline", "status")
      assert_equal 1, report.dig("baseline", "executed_tests")
      assert_includes Array(report.dig("run_metadata", "runner_args")), "2468"
      framework = report.dig("run_metadata", "framework") || report.dig("baseline", "project", "framework")
      assert_equal "rspec", framework
      phases = report.dig("observations", "tests").flat_map { |test| test.fetch("phase_counts").keys }
      assert_includes phases, "setup"
      assert_includes phases, "body"
      assert_includes phases, "teardown"

      terminal = run_cli(root, ["report", "report.json", "--view", "tests"])
      assert terminal.fetch(:status).success?, terminal.fetch(:stderr)
      assert_includes terminal.fetch(:stdout), "Access allows admins"
      decisions = run_cli(root, ["report", "report.json", "--view", "decision-tables"])
      assert decisions.fetch(:status).success?, decisions.fetch(:stderr)
      assert_includes decisions.fetch(:stdout), "Coverage ladder"
      %w[decisions conditions tests decision-tables].each do |view|
        missing = run_cli(root, ["report", "report.json", "--view", view, "--missing-only"])
        assert missing.fetch(:status).success?, "#{view}: #{missing.fetch(:stderr)}"
        refute_empty missing.fetch(:stdout), view
      end
    end
  end

  def test_levels_missing_only_filter_and_json_output_are_forwarded
    with_project do |root|
      write_rspec_project(root, <<~RUBY)
        RSpec.describe "Selection" do
          it("selected") { expect(branchproof_value(true)).to eq(:yes) }
          it("ignored") { expect(branchproof_value(false)).to eq(:no) }
        end
      RUBY
      reports = [1, 2, 3].map do |level|
        result = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--format", "json",
                                "--test", "spec/access_spec.rb", "--level", level.to_s, "--",
                                "--seed", "111"])
        assert result.fetch(:status).success?, result.fetch(:stderr)
        result.fetch(:json)
      end
      reports.each do |report|
        coverage = report.dig("analysis", "coverage")
        refute_nil coverage
        refute_nil coverage["decision"]
        refute_nil coverage["condition"]
      end
      assert_equal reports.first.dig("analysis", "coverage"), reports.last.dig("analysis", "coverage")

      filtered = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--format", "json",
                                "--test", "spec/access_spec.rb", "--", "--example", "selected", "--seed", "111"])
      assert filtered.fetch(:status).success?, filtered.fetch(:stderr)
      assert_equal 1, filtered.dig(:json, "baseline", "executed_tests")
      assert_includes Array(filtered.dig(:json, "run_metadata", "runner_args")), "111"
    end
  end

  def test_failures_pending_skips_empty_and_non_example_failures_have_distinct_statuses
    with_project do |root|
      write_rspec_project(root, <<~RUBY)
        RSpec.describe "Statuses" do
          it("fails") { expect(1).to eq(2) }
          it("pending") { pending("later"); expect(1).to eq(2) }
          it("skipped") { skip("later") }
        end
      RUBY
      failed = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--format", "json",
                              "--test", "spec/access_spec.rb"])
      assert_equal 1, failed.fetch(:status).exitstatus, failed.fetch(:stderr)
      assert_equal "FAILED", failed.dig(:json, "baseline", "status")
      assert_equal 1, failed.dig(:json, "baseline", "failed_tests")
      assert_equal 2, failed.dig(:json, "baseline", "skipped_tests")

      File.write(File.join(root, "spec", "access_spec.rb"), "RSpec.describe(\"Empty\") { }\n")
      empty = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--format", "json",
                             "--test", "spec/access_spec.rb"])
      assert_equal 2, empty.fetch(:status).exitstatus
      assert_equal "INCOMPLETE", empty.dig(:json, "baseline", "status")
      assert_equal 0, empty.dig(:json, "baseline", "executed_tests")
    end
  end

  def test_rspec_status_matrix_preserves_native_exit_and_baseline_counts
    cases = {
      "all-skipped" => {
        source: 'RSpec.describe { it("one") { skip("later") }; it("two") { skip("later") } }',
        baseline: "PASSED", executed: 2, failed: 0, skipped: 2, exit: 0
      },
      "filtered-empty" => {
        source: 'RSpec.describe("filter") { it("present") { expect(true).to be(true) } }',
        args: ["--example", "does-not-exist"], baseline: "INCOMPLETE", executed: 0, failed: 0, skipped: 0, exit: 2
      },
      "context-failure" => {
        source: 'RSpec.describe { before(:context) { raise "context exploded" }; it("body") { raise "must not run" } }',
        baseline: "FAILED", executed: 1, failed: 1, skipped: 0, exit: 1
      },
      "context-skip" => {
        source: 'RSpec.describe { before(:context) { skip("context skip") }; it("body") { raise "must not run" } }',
        baseline: "PASSED", executed: 1, failed: 0, skipped: 1, exit: 0
      },
      "suite-error" => {
        source: 'RSpec.configure { |c| c.failure_exit_code = 0; c.before(:suite) { raise "suite exploded" } }; RSpec.describe { it { raise "must not run" } }',
        baseline: "ERROR", executed: 0, failed: 0, skipped: 0, exit: 2
      },
      "fail-fast" => {
        source: 'RSpec.describe { it("bad") { expect(false).to be(true) }; it("later") { raise "must not run" } }',
        args: ["--fail-fast"], baseline: "FAILED", executed: 1, failed: 1, skipped: 0, exit: 1
      },
      "failure-exit-zero" => {
        source: "RSpec.configure { |c| c.failure_exit_code = 0 }; RSpec.describe { it { expect(false).to be(true) } }",
        baseline: "FAILED", executed: 1, failed: 1, skipped: 0, exit: 1
      },
      "failure-exit-seven" => {
        source: "RSpec.configure { |c| c.failure_exit_code = 7 }; RSpec.describe { it { expect(false).to be(true) } }",
        baseline: "FAILED", executed: 1, failed: 1, skipped: 0, exit: 1
      }
    }

    with_project do |root|
      cases.each do |name, expected|
        write_rspec_project(root, expected.fetch(:source))
        result = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--format", "json",
                                "--test", "spec/access_spec.rb", "--", *Array(expected[:args])])
        report = result.fetch(:json)
        assert_equal expected.fetch(:exit), result.fetch(:status).exitstatus, name
        assert_equal expected.fetch(:baseline), report.dig("baseline", "status"), name
        assert_equal expected.fetch(:executed), report.dig("baseline", "executed_tests"), name
        assert_equal expected.fetch(:failed), report.dig("baseline", "failed_tests"), name
        assert_equal expected.fetch(:skipped), report.dig("baseline", "skipped_tests"), name
        if %w[context-failure context-skip].include?(name)
          observations = report.dig("observations", "vectors")
          assert_empty observations, name
        end
      end
    end
  end

  def test_comparison_mentions_framework_when_reports_use_different_adapters
    with_project do |root|
      write_rspec_project(root, "RSpec.describe(\"Access\") { it(\"passes\") { expect(true).to eq(true) } }\n")
      rspec = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--format", "json",
                             "--test", "spec/access_spec.rb", "--output", "rspec.json"])
      assert rspec.fetch(:status).success?, rspec.fetch(:stderr)

      minitest_root = File.join(root, "minitest")
      FileUtils.mkdir_p(File.join(minitest_root, "test"))
      FileUtils.mkdir_p(File.join(minitest_root, "lib"))
      File.write(File.join(minitest_root, "lib", "decision.rb"), File.read(File.join(root, "lib", "decision.rb")))
      File.write(File.join(minitest_root, "test", "decision_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require "decision"
        class AccessTest < Minitest::Test
          def test_passes
            assert_equal :yes, branchproof_value(true)
          end
        end
      RUBY
      minitest = run_cli(minitest_root, ["analyze", "lib/decision.rb", "--format", "json",
                                         "--test", "test/decision_test.rb", "--output", "minitest.json"])
      assert minitest.fetch(:status).success?, minitest.fetch(:stderr)
      comparison = run_cli(root, ["compare", "minitest/minitest.json", "rspec.json", "--format", "terminal"])
      assert_includes [1, 2], comparison.fetch(:status).exitstatus
      assert_includes comparison.fetch(:stdout).downcase, "framework"
      same = run_cli(root, ["compare", "rspec.json", "rspec.json", "--format", "terminal"])
      assert same.fetch(:status).success?, same.fetch(:stderr)
    end
  end

  def test_default_discovery_respects_exclusions_and_custom_patterns
    with_project do |root|
      write_rspec_project(root, 'RSpec.describe("included") { it("works") { expect(true).to be(true) } }')
      File.write(File.join(root, "spec", "excluded_spec.rb"), 'raise "excluded file loaded"')
      excluded = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--format", "json",
                                "--", "--exclude-pattern", "spec/excluded_spec.rb"])
      assert excluded.fetch(:status).success?, excluded.fetch(:stderr)
      assert_equal 1, excluded.dig(:json, "baseline", "executed_tests")
      File.write(File.join(root, "spec", "custom_check.rb"), 'RSpec.describe("custom") { it("works") { expect(true).to be(true) } }')
      custom = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--format", "json",
                              "--", "--pattern", "spec/**/*_check.rb"])
      assert custom.fetch(:status).success?, custom.fetch(:stderr)
      assert_equal(["custom works"], custom.dig(:json, "observations", "tests").map { |test| test.fetch("name") })
    end
  end

  def test_empty_selection_explains_unmatched_globs_filters_and_empty_suites
    with_project do |root|
      write_rspec_project(root, 'RSpec.describe("present") { it("works") { expect(true).to be(true) } }')
      base = ["analyze", "lib/decision.rb", "--framework", "rspec", "--format", "json"]
      unmatched = run_cli(root, [*base, "--test", "spec/missing*_spec.rb"])
      assert_equal "INCOMPLETE", unmatched.dig(:json, "baseline", "status")
      assert_equal 0, unmatched.dig(:json, "baseline", "executed_tests")
      assert_includes unmatched.fetch(:stdout), "unmatched_test_selection"
      filtered = run_cli(root, [*base, "--", "--example", "missing"])
      assert_includes filtered.fetch(:stdout), "empty_example_selection"
      File.write(File.join(root, "spec", "access_spec.rb"), 'RSpec.describe("empty") {}')
      empty = run_cli(root, base)
      assert_includes empty.fetch(:stdout), "empty_suite"
    end
  end

  def test_default_discovery_uses_the_configured_default_path_and_helper_pattern
    with_project do |root|
      write_rspec_project(root, 'raise "default spec must not load"')
      FileUtils.mkdir_p(File.join(root, "behavior"))
      File.write(File.join(root, "behavior", "custom_check.rb"), 'RSpec.describe("custom") { it("works") { expect(true).to be(true) } }')
      File.write(File.join(root, "spec", "spec_helper.rb"), <<~RUBY)
        require "rspec/expectations"
        RSpec.configure { |config| config.pattern = "**/*_check.rb" }
      RUBY
      result = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--format", "json",
                              "--", "--default-path", "behavior"])
      assert result.fetch(:status).success?, result.fetch(:stderr)
      assert_equal(["custom works"], result.dig(:json, "observations", "tests").map { |test| test.fetch("name") })
    end
  end

  def test_default_discovery_is_available_to_required_helpers
    with_project do |root|
      write_rspec_project(root, 'RSpec.describe("present") { it("works") { expect(true).to be(true) } }')
      File.write(File.join(root, "spec", "spec_helper.rb"), <<~RUBY)
        require "rspec/expectations"
        raise "discovery missing during helper load" unless RSpec.configuration.files_to_run.any? { |path| path.end_with?("access_spec.rb") }
      RUBY
      result = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--format", "json"])
      assert result.fetch(:status).success?, result.fetch(:stderr)
      assert_equal 1, result.dig(:json, "baseline", "executed_tests")
    end
  end

  private

  def with_project(&)
    Dir.mktmpdir("branchproof-rspec-acceptance-", &)
  end

  def write_rspec_project(root, spec)
    FileUtils.mkdir_p(File.join(root, "lib"))
    FileUtils.mkdir_p(File.join(root, "spec"))
    File.write(File.join(root, "lib", "decision.rb"), <<~RUBY)
      def branchproof_value(value)
        if value
          :yes
        else
          :no
        end
      end
    RUBY
    File.write(File.join(root, "spec", "spec_helper.rb"), "require \"rspec/expectations\"\n")
    File.write(File.join(root, "spec", "access_spec.rb"), "require \"spec_helper\"\nrequire \"decision\"\n#{spec}")
    File.write(File.join(root, ".rspec"), "--require spec_helper\n--format progress\n")
  end

  def run_cli(root, args)
    stdout, stderr, status = Open3.capture3({ "MT_NO_PLUGINS" => "1" }, RbConfig.ruby, EXECUTABLE, *args, chdir: root)
    output_path = args[args.index("--output") + 1] if args.include?("--output")
    output_json = output_path && File.file?(File.join(root, output_path)) && JSON.parse(File.read(File.join(root, output_path)))
    json = if args.first == "analyze" || (args.first == "report" && args.include?("--format") && args.include?("json"))
             output_json || JSON.parse(stdout)
           end
    { stdout: stdout, stderr: stderr, status: status, json: json, output_json: output_json }
  rescue JSON::ParserError => e
    flunk "expected JSON output, got #{stdout.inspect}: #{e.message}; stderr=#{stderr}"
  end
end
