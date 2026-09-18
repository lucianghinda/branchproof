# frozen_string_literal: true

require "test_helper"
require "open3"
require "json"
require "fileutils"

class TestRSpecSafety < Minitest::Test
  def test_suite_failures_have_diagnostics_and_incomplete_observation
    report, status = analyze(<<~RUBY)
      RSpec.configure do |config|
        config.failure_exit_code = 0
        config.after(:suite) { raise "suite cleanup failed" }
      end
      RSpec.describe("Suite") { it("passes") { expect(check(true)).to eq(true) } }
    RUBY

    assert_equal 2, status.exitstatus
    assert_equal "ERROR", report.dig("baseline", "status")
    refute report.dig("baseline", "finalized")
    refute_empty report.fetch("diagnostics")
    refute report.dig("observations", "completeness", "observation")
  end

  def test_helper_cannot_enable_dry_run_and_get_a_passing_report
    report, status = analyze(<<~RUBY)
      RSpec.configure { |config| config.dry_run = true }
      RSpec.describe("Dry") { it("never runs") { check(true) } }
    RUBY

    assert_equal 2, status.exitstatus
    assert_equal "ERROR", report.dig("baseline", "status")
    assert_match(/dry.run/, report.fetch("diagnostics").map { |row| row.fetch("message") }.join)
    assert_equal 1, report.dig("baseline", "selected_test_files").length
    assert_equal 1, report.dig("baseline", "selected_example_ids").length
  end

  def test_around_hooks_cannot_execute_the_same_example_twice
    report, status = analyze(<<~RUBY)
      RSpec.describe("Repeated") do
        around { |example| 2.times { example.run } }
        it("runs twice") { check(true) }
      end
    RUBY

    assert_equal 2, status.exitstatus
    assert_equal "ERROR", report.dig("baseline", "status")
    assert_match(/repeat/, report.fetch("diagnostics").map { |row| row.fetch("message") }.join)
  end

  def test_rescuing_a_nested_runner_does_not_hide_unsupported_execution
    ["RSpec::Core::Runner.run([])", "RSpec::Core::Runner.new(RSpec::Core::ConfigurationOptions.new([])).run"].each do |call|
      report, status = analyze(<<~RUBY)
        RSpec.describe("Nested") do
          it("rescues the nested invocation") do
            begin
              #{call}
            rescue ArgumentError
            end
            check(true)
          end
        end
      RUBY
      assert_equal 2, status.exitstatus
      assert_equal "ERROR", report.dig("baseline", "status")
      assert_match(/nested/, report.fetch("diagnostics").map { |row| row.fetch("message") }.join)
    end
  end

  def test_rescued_at_exit_runner_cannot_run_after_report_finalization
    report, status = analyze(<<~RUBY)
      at_exit do
        begin
          RSpec::Core::Runner.run([])
        rescue ArgumentError
        end
      end
      RSpec.describe("Late") { it("runs once") { check(true) } }
    RUBY
    assert_equal 2, status.exitstatus
    assert_equal "ERROR", report.dig("baseline", "status")
    assert_equal 1, report.dig("baseline", "executed_tests")
    refute report.dig("baseline", "finalized")
    refute report.dig("observations", "completeness", "observation")
    assert_match(/repeated/, report.fetch("diagnostics").map { |row| row.fetch("message") }.join)
  end

  def test_suite_hook_cannot_enable_dry_run_after_configuration_validation
    report, status = analyze(<<~RUBY)
      RSpec.configure { |config| config.before(:suite) { config.dry_run = true } }
      RSpec.describe("Late dry run") { it("must execute") { check(true) } }
    RUBY
    assert_equal 2, status.exitstatus
    assert_equal "ERROR", report.dig("baseline", "status")
    refute report.dig("baseline", "finalized")
  end

  private

  def analyze(spec)
    Dir.mktmpdir("branchproof-rspec-safety") do |root|
      FileUtils.mkdir_p([File.join(root, "lib"), File.join(root, "spec")])
      File.write(File.join(root, "lib", "check.rb"), "def check(value); if value; true; else; false; end; end\n")
      File.write(File.join(root, "spec", "check_spec.rb"), "require 'check'\n#{spec}")
      executable = File.expand_path("../exe/branchproof", __dir__)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, executable, "analyze", "lib/check.rb",
                                              "--framework", "rspec", "--format", "json", chdir: root)
      assert !stdout.empty?, stderr
      [JSON.parse(stdout), status]
    end
  end
end
