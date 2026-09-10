# frozen_string_literal: true

require "test_helper"
require "branchproof/cli"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

class TestCLI < Minitest::Test
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
end
