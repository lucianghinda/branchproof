# frozen_string_literal: true

require "test_helper"
require "branchproof/cli"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

class TestCLI < Minitest::Test
  def test_views_are_explicit_terminal_options
    cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
    assert_equal :conditions, cli.send(:parse, ["analyze", "--view", "conditions"])[:view]
    assert_raises(ArgumentError) { cli.send(:parse, ["analyze", "--view", "tests", "--format", "json"]) }
    assert_raises(ArgumentError) { cli.send(:parse, ["analyze", "--view", "unknown"]) }
    assert_equal false, cli.send(:value, { finalized: false }, :finalized)
  end

  def test_minimum_flags_are_normalized_merged_and_rejected_before_execution
    cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
    options = cli.send(:parse, ["analyze", "--minimum", "mcdc=66.67", "--minimum", "decision=80"])
    assert_equal({ "mcdc" => 66.67, "decision" => 80 }, options[:minimum])
    assert_raises(ArgumentError) { cli.send(:parse, ["analyze", "--minimum", "mcdc=80", "--minimum", "mcdc=90"]) }
    assert_raises(ArgumentError) { cli.send(:parse, ["analyze", "--minimum", "unknown=80"]) }
    assert_raises(ArgumentError) { cli.send(:parse, ["analyze", "--minimum", "mcdc=NaN"]) }
    assert_raises(ArgumentError) { cli.send(:parse, ["analyze", "--format", "json", "--focus", "lib/a.rb"]) }
    assert_raises(ArgumentError) { cli.send(:parse, ["analyze", "--top"]) }
  end

  def test_primary_help_lists_offline_commands
    stdout = StringIO.new
    status = Branchproof::CLI.new(stdout: stdout, stderr: StringIO.new).call(["--help"])
    assert_equal 0, status
    assert_includes stdout.string, "branchproof report"
    assert_includes stdout.string, "branchproof compare"
  end

  FIXTURE_ROOT = File.expand_path("fixtures/cli", __dir__)

  def test_empty_command_is_usage_error_without_report_on_stdout
    stdout = StringIO.new
    stderr = StringIO.new
    status = Branchproof::CLI.new(stdout: stdout, stderr: stderr).call([])
    assert_equal 2, status
    assert_empty stdout.string
    refute_empty stderr.string
  end

  def test_level_outside_supported_range_is_usage_error
    stderr = StringIO.new
    status = Branchproof::CLI.new(stdout: StringIO.new, stderr: stderr).call(["analyze", "--level", "4"])
    assert_equal 2, status
    assert_includes stderr.string, "level"
  end

  def test_missing_only_rejects_observation_only_and_json_reports
    [["--level", "1"], ["--format", "json"]].each do |options|
      stdout = StringIO.new
      stderr = StringIO.new
      status = Branchproof::CLI.new(stdout: stdout, stderr: stderr).call(["analyze", "--missing-only", *options])

      assert_equal 2, status
      assert_empty stdout.string
      assert_includes stderr.string, "--missing-only requires terminal format and level 2 or 3"
    end
  end

  def test_missing_only_reports_a_missing_case_without_proven_condition_noise
    Dir.mktmpdir do |root|
      source = File.join(root, "decision.rb")
      File.binwrite(source, File.binread(File.join(FIXTURE_ROOT, "decision.rb")))
      test_file = File.join(root, "test_decision.rb")
      File.write(test_file, <<~RUBY)
        require #{source.inspect}
        require "minitest/autorun"
        class MissingCaseTest < Minitest::Test
          def test_present
            assert_equal :yes, CliFixture.decide(true, true)
          end
          def test_absent
            assert_equal :no, CliFixture.decide(false, true)
          end
        end
      RUBY
      stdout = StringIO.new
      stderr = StringIO.new
      status = Branchproof::CLI.new(stdout: stdout, stderr: stderr).call([
                                                                           "analyze", source, "--test", test_file, "--missing-only"
                                                                         ])

      assert_equal 0, status, stderr.string
      assert_includes stdout.string, "Tests: PASSED (2 tests"
      assert_includes stdout.string, "Condition 1: right"
      refute_includes stdout.string, "Condition 0: left"
      refute_includes stdout.string, "Supporting sets:"
      refute_includes stdout.string, "INFEASIBLE_IN_MODEL"
    end
  end

  def test_positive_fixture_runs_once_and_reports_vectors_and_witnesses
    Dir.mktmpdir do |root|
      source = File.join(root, "decision.rb")
      File.binwrite(source, File.binread(File.join(FIXTURE_ROOT, "decision.rb")))
      test_file = File.join(root, "test_decision_test.rb")
      test_source = File.binread(File.join(FIXTURE_ROOT, "test_decision_test.rb"))
                        .sub('require_relative "decision"', "require #{source.inspect}")
      File.binwrite(test_file, test_source)
      stdout = StringIO.new
      stderr = StringIO.new
      status = Branchproof::CLI.new(stdout: stdout, stderr: stderr).call([
                                                                           "analyze", source, "--format", "json", "--test", test_file
                                                                         ])
      assert_equal 0, status, stderr.string
      document = JSON.parse(stdout.string)
      assert_equal "PASSED", document.dig("baseline", "status")
      assert_equal(3, document.dig("observations", "vectors").sum { |vector| vector.fetch("count") })
      assert_equal 2, document.dig("analysis", "proven_count")
      assert_equal 100.0, document.dig("metrics", "percentage")
      assert_equal 3, document.dig("baseline", "executed_tests")
      phases = document.dig("observations", "tests").flat_map { |test| test.fetch("phase_counts").keys }
      assert_includes phases, "setup"
      assert_includes phases, "body"
      assert_includes phases, "teardown"

      level_two_output = StringIO.new
      level_two_status = Branchproof::CLI.new(stdout: level_two_output, stderr: StringIO.new).call([
                                                                                                     "analyze", source, "--level", "2", "--format", "json", "--test", test_file
                                                                                                   ])
      level_two_document = JSON.parse(level_two_output.string)
      assert_equal 0, level_two_status
      refute_empty level_two_document.fetch("minima")
    end
  end

  def test_default_project_tests_are_union_without_helpers_support_or_fixtures
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "test", "support"))
      FileUtils.mkdir_p(File.join(root, "test", "fixtures"))
      %w[alpha_test.rb test_beta.rb test_helper.rb support/helper_test.rb fixtures/test_fixture.rb].each do |name|
        path = File.join(root, "test", name)
        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.touch(path)
      end

      Dir.chdir(root) do
        cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
        options = cli.send(:parse, ["analyze"])

        assert_equal %w[alpha_test.rb test_beta.rb].map { |name| File.join(File.realpath(root), "test", name) }, options[:tests]
      end
    end
  end

  def test_project_option_is_transported_and_rails_environment_does_not_change_parent
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      FileUtils.touch(File.join(root, "config", "application.rb"))
      FileUtils.touch(File.join(root, "config", "environment.rb"))
      Dir.chdir(root) do
        cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
        options = cli.send(:parse, ["analyze", "--project", "rails", "--test", "test/foo_test.rb"])

        assert_equal "rails", options[:project][:kind]
        assert_equal "test", options[:project][:environment].fetch("RAILS_ENV")
        refute_equal "test", ENV.fetch("RAILS_ENV", nil)
      end
    end
  end

  def test_invalid_project_mode_is_usage_error
    stderr = StringIO.new

    status = Branchproof::CLI.new(stdout: StringIO.new, stderr: stderr).call(["analyze", "--project", "wat"])

    assert_equal 2, status
    assert_includes stderr.string, "project must be auto, ruby, or rails"
  end

  def test_framework_and_project_options_are_resolved_after_all_arguments
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "spec"))
      FileUtils.touch(File.join(root, "spec/example_spec.rb"))
      Dir.chdir(root) do
        cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
        options = cli.send(:parse, ["analyze", "--framework", "rspec", "--project", "ruby"])

        assert_equal "ruby", options[:project][:kind]
        assert_equal "rspec", options[:project][:framework]
        assert_equal [File.realpath(File.join(root, "spec", "example_spec.rb"))], options[:tests]
      end
    end
  end

  def test_repeated_project_and_framework_options_use_the_last_values
    cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
    options = cli.send(:parse, ["analyze", "--project", "ruby", "--framework", "minitest",
                                "--project", "auto", "--framework", "rspec"])

    assert_equal "auto", options[:project_mode]
    assert_equal "rspec", options[:framework]
    assert_equal "rspec", options[:project][:framework]
  end

  def test_run_metadata_prefers_selected_files_from_string_keyed_baseline
    Dir.mktmpdir do |root|
      cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
      options = cli.send(:parse, ["analyze", "--framework", "rspec"])
      options[:project] = options[:project].merge(root: root)
      baseline = { "project" => { "framework" => "rspec", "framework_version" => "3.13.0" },
                   "selected_test_files" => [File.join(root, "spec", "selected_spec.rb")],
                   "selected_example_ids" => ["spec/example_spec.rb[1]"], "tests" => [] }

      metadata = cli.send(:run_metadata, options, baseline)

      assert_equal ["spec/selected_spec.rb"], metadata[:test_files]
      assert_equal ["spec/example_spec.rb[1]"], metadata[:selected_example_ids]
      assert_equal "rspec", metadata[:framework]
      assert_equal "3.13.0", metadata[:framework_version]
    end
  end

  def test_rspec_empty_discovery_still_runs_worker
    cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
    options = { tests: [], project: { framework: "rspec" } }

    assert cli.send(:run_worker?, options)
    refute cli.send(:run_worker?, options.merge(project: { framework: "minitest" }))
  end

  def test_worker_payload_carries_explicit_selection_flag
    cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
    evidence = Struct.new(:run_id).new("run-id")
    options = { limits: {}, tests: [], runner_args: [], project: {}, explicit_tests: true }
    payload = cli.send(:worker_payload, options, {}, evidence, "/tmp/branchproof-test")

    assert_equal true, payload[:test_selection_explicit]
    options[:explicit_tests] = false
    assert_equal false, cli.send(:worker_payload, options, {}, evidence, "/tmp/branchproof-test")[:test_selection_explicit]
  end

  def test_config_options_are_parsed_before_runner_delimiter
    Dir.mktmpdir do |root|
      File.write(File.join(root, ".branchproof.json"), JSON.generate(schema_version: 1, project: "ruby",
                                                                     framework: "minitest",
                                                                     sources: ["configured/**/*.rb"],
                                                                     tests: ["configured_test.rb"]))
      FileUtils.touch(File.join(root, "configured_test.rb"))
      Dir.chdir(root) do
        cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
        options = cli.send(:parse, ["analyze", "--config", ".branchproof.json", "--", "--config", "runner.json"])

        assert_equal ["--config", "runner.json"], options[:runner_args]
        assert_equal "ruby", options[:project_mode]
        assert_equal "minitest", options[:framework]
        assert_equal [File.realpath(File.join(root, "configured_test.rb"))], options[:tests]
        assert_equal true, options[:explicit_tests]
      end
    end
  end

  def test_cli_minimum_overrides_one_config_criterion_and_retains_the_rest
    Dir.mktmpdir do |root|
      File.write(File.join(root, ".branchproof.json"), JSON.generate(schema_version: 1,
                                                                     minimum: { mcdc: 70, decision: 80 }))
      Dir.chdir(root) do
        cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
        options = cli.send(:parse, ["analyze", "--minimum", "mcdc=90"])

        assert_equal({ "mcdc" => 90, "decision" => 80 }, options[:minimum])
      end
    end
  end

  def test_cli_sources_and_tests_replace_configured_selections_and_cli_project_values_win
    Dir.mktmpdir do |root|
      File.write(File.join(root, ".branchproof.json"), JSON.generate(schema_version: 1, project: "rails",
                                                                     framework: "rspec",
                                                                     sources: ["configured/**/*.rb"],
                                                                     tests: ["configured/**/*_spec.rb"]))
      Dir.chdir(root) do
        cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
        options = cli.send(:parse, ["analyze", "cli/**/*.rb", "--test", "cli/**/*_test.rb", "--project", "ruby",
                                    "--framework", "minitest"])

        assert_equal "ruby", options[:project_mode]
        assert_equal "minitest", options[:framework]
        assert_equal ["cli/**/*.rb"], options[:source_patterns]
        assert_equal ["cli/**/*_test.rb"], options[:test_patterns]
        assert_equal true, options[:explicit_tests]
      end
    end
  end

  def test_config_and_no_config_are_mutually_exclusive
    cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
    assert_raises(ArgumentError) { cli.send(:parse, ["analyze", "--config", "policy.json", "--no-config"]) }
  end

  def test_disabled_config_keeps_default_discovery
    Dir.mktmpdir do |root|
      File.write(File.join(root, ".branchproof.json"), JSON.generate(schema_version: 1, sources: ["configured/**/*.rb"],
                                                                     tests: ["configured_test.rb"]))
      FileUtils.mkdir_p(File.join(root, "test"))
      FileUtils.touch(File.join(root, "test", "default_test.rb"))
      Dir.chdir(root) do
        cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
        options = cli.send(:parse, ["analyze", "--no-config"])

        assert_equal [File.realpath(File.join(root, "test/default_test.rb"))], options[:tests]
        assert_equal %w[lib/**/*.rb app/**/*.rb], options[:source_patterns]
      end
    end
  end
end
