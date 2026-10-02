# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "rake"
require "rbconfig"
require "tmpdir"
require "branchproof/rake_task"

class RakeTaskTest < Minitest::Test
  FIXTURE_ROOT = File.expand_path("fixtures/cli", __dir__)
  GEM_ROOT = File.expand_path("..", __dir__)

  def setup
    Rake.application = Rake::Application.new
    Rake::TaskManager.record_task_metadata = true
    @task_count = 0
  end

  def teardown
    Rake.application = Rake::Application.new
  end

  def test_defaults_build_a_bare_analyze_command
    task = define_task

    assert_equal ["analyze"], task.argv
    assert_equal [], task.sources
    assert_equal [], task.tests
    assert_equal "auto", task.project
    assert_equal "auto", task.framework
    assert_equal "decisions", task.view
    assert_equal 3, task.level
    assert_equal false, task.missing_only
    assert_equal [], task.minimum
    assert_equal "terminal", task.format
    assert_nil task.output
    assert_equal [], task.runner_args
  end

  def test_defines_a_described_rake_task
    task = define_task(:custom_name) { |t| t.description = "Check coverage" }

    assert_equal :custom_name, task.name
    rake_task = Rake::Task[:custom_name]
    assert_equal "Check coverage", rake_task.comment
  end

  def test_default_description_is_present
    define_task(:described)

    assert_equal "Run branchproof analyze", Rake::Task[:described].comment
  end

  def test_sources_are_positional_arguments
    task = define_task { |t| t.sources = ["lib/**/*.rb", "app/**/*.rb"] }

    assert_equal ["analyze", "lib/**/*.rb", "app/**/*.rb"], task.argv
  end

  def test_a_single_source_string_is_accepted
    task = define_task { |t| t.sources = "lib/**/*.rb" }

    assert_equal ["analyze", "lib/**/*.rb"], task.argv
  end

  def test_tests_become_repeated_test_flags
    task = define_task { |t| t.tests = ["test/**/*_test.rb", "test/**/test_*.rb"] }

    assert_equal ["analyze", "--test", "test/**/*_test.rb", "--test", "test/**/test_*.rb"], task.argv
  end

  def test_mutating_repeated_option_arrays_emits_flags
    task = define_task do |t|
      extra_tests = ["test/second_test.rb"]
      extra_minimums = ["decision=90"]
      t.tests << "test/first_test.rb"
      t.tests.concat(extra_tests)
      t.minimum << "mcdc=100"
      t.minimum.concat(extra_minimums)
    end

    assert_equal ["analyze", "--test", "test/first_test.rb", "--test", "test/second_test.rb",
                  "--minimum", "mcdc=100", "--minimum", "decision=90"], task.argv
  end

  def test_project_flag
    task = define_task { |t| t.project = "rails" }

    assert_equal ["analyze", "--project", "rails"], task.argv
  end

  def test_framework_flag
    task = define_task { |t| t.framework = "rspec" }

    assert_equal ["analyze", "--framework", "rspec"], task.argv
  end

  def test_framework_set_to_the_default_is_still_passed_explicitly
    task = define_task { |t| t.framework = "auto" }

    assert_equal ["analyze", "--framework", "auto"], task.argv
  end

  def test_view_flag
    task = define_task { |t| t.view = "decision-tables" }

    assert_equal ["analyze", "--view", "decision-tables"], task.argv
  end

  def test_level_flag_is_stringified
    task = define_task { |t| t.level = 1 }

    assert_equal ["analyze", "--level", "1"], task.argv
  end

  def test_missing_only_flag
    task = define_task { |t| t.missing_only = true }

    assert_equal ["analyze", "--missing-only"], task.argv
  end

  def test_missing_only_false_passes_no_flag
    task = define_task { |t| t.missing_only = false }

    assert_equal ["analyze"], task.argv
  end

  def test_minimum_becomes_repeated_minimum_flags
    task = define_task { |t| t.minimum = ["mcdc=100", "decision=90"] }

    assert_equal ["analyze", "--minimum", "mcdc=100", "--minimum", "decision=90"], task.argv
  end

  def test_format_flag
    task = define_task { |t| t.format = "json" }

    assert_equal ["analyze", "--format", "json"], task.argv
  end

  def test_output_flag
    task = define_task { |t| t.output = "tmp/branchproof.json" }

    assert_equal ["analyze", "--output", "tmp/branchproof.json"], task.argv
  end

  def test_output_nil_passes_no_flag
    task = define_task { |t| t.output = nil }

    assert_equal ["analyze"], task.argv
  end

  def test_runner_args_are_appended_after_the_separator
    task = define_task do |t|
      t.sources = ["lib/**/*.rb"]
      t.runner_args = ["--seed", "1234"]
    end

    assert_equal ["analyze", "lib/**/*.rb", "--", "--seed", "1234"], task.argv
  end

  def test_all_options_together_keep_a_stable_order
    task = define_task do |t|
      t.sources = ["lib/**/*.rb"]
      t.tests = ["test/**/*_test.rb"]
      t.project = "ruby"
      t.framework = "minitest"
      t.view = "conditions"
      t.level = 2
      t.missing_only = true
      t.minimum = ["mcdc=100"]
      t.format = "terminal"
      t.output = "tmp/report.txt"
      t.runner_args = ["-n", "/checkout/"]
    end

    expected = ["analyze", "lib/**/*.rb", "--test", "test/**/*_test.rb", "--project", "ruby",
                "--framework", "minitest", "--view", "conditions", "--level", "2", "--missing-only",
                "--minimum", "mcdc=100", "--format", "terminal", "--output", "tmp/report.txt",
                "--", "-n", "/checkout/"]
    assert_equal expected, task.argv
  end

  def test_command_uses_the_current_ruby_and_the_gem_executable
    task = define_task { |t| t.sources = ["lib/**/*.rb"] }

    assert_equal RbConfig.ruby, task.command[0]
    assert_equal File.join(GEM_ROOT, "exe", "branchproof"), task.command[1]
    assert_equal task.argv, task.command[2..]
  end

  def test_running_the_task_writes_a_json_report_for_the_fixture_project
    Dir.mktmpdir("branchproof-rake-task-") do |dir|
      output = File.join(dir, "report.json")
      define_task(:fixture_run) do |t|
        t.sources = ["decision.rb"]
        t.tests = ["test_decision_test.rb"]
        t.format = "json"
        t.output = output
      end

      capture_subprocess_io { with_fixture_environment { Rake::Task[:fixture_run].invoke } }

      document = JSON.parse(File.binread(output))
      assert_equal "PASSED", document.dig("baseline", "status")
      assert_equal 3, document.dig("baseline", "executed_tests")
    end
  end

  def test_running_the_task_exits_with_the_cli_status_on_failure
    define_task(:fixture_gate) do |t|
      t.sources = ["decision.rb"]
      t.tests = ["missing_test.rb"]
      t.format = "json"
    end

    error = capture_subprocess_io do
      @error = assert_raises(SystemExit) { with_fixture_environment { Rake::Task[:fixture_gate].invoke } }
    end

    assert_equal 2, @error.status
    assert_includes error.last, "branchproof exited with status 2"
  end

  def test_appending_a_minimum_gate_exits_with_the_cli_status_when_gate_fails
    define_task(:fixture_gate) do |t|
      t.sources = ["decision.rb"]
      t.tests = ["test_decision_test.rb"]
      t.minimum << "mcdc=100"
      t.format = "json"
      t.runner_args = ["-n", "/test_true_true_vector/"]
    end

    error = capture_subprocess_io do
      @error = assert_raises(SystemExit) { with_fixture_environment { Rake::Task[:fixture_gate].invoke } }
    end

    assert_equal 1, @error.status, error.last
    assert_includes error.last, "branchproof exited with status 1"
  end

  private

  def define_task(name = nil, &)
    @task_count += 1
    Branchproof::RakeTask.new(name || :"branchproof_#{@task_count}", &)
  end

  def with_fixture_environment(&)
    previous = ENV.fetch("MT_NO_PLUGINS", nil)
    ENV["MT_NO_PLUGINS"] = "1"
    Dir.chdir(FIXTURE_ROOT, &)
  ensure
    previous ? ENV["MT_NO_PLUGINS"] = previous : ENV.delete("MT_NO_PLUGINS")
  end
end
