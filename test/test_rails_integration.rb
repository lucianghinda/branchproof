# frozen_string_literal: true

require "test_helper"
require "json"
require "fileutils"
require "tmpdir"
require "branchproof/cli"

class TestRailsIntegration < Minitest::Test
  FIXTURE = File.expand_path("fixtures/rails_app", __dir__).freeze

  def test_real_rails_application_runs_lazy_and_eager_with_serial_override
    unless ENV["BRANCHPROOF_RAILS_INTEGRATION"] == "1"
      skip "set BRANCHPROOF_RAILS_INTEGRATION=1 to run the Rails integration"
    end

    [false, true].each do |eager|
      Dir.mktmpdir("branchproof-rails-fixture-") do |root|
        copy_fixture(root)
        before = application_source(root)
        previous = ENV.fetch("BRANCHPROOF_FIXTURE_EAGER", nil)
        ENV["BRANCHPROOF_FIXTURE_EAGER"] = eager ? "1" : "0"

        stdout = StringIO.new
        stderr = StringIO.new
        exit_code = Dir.chdir(root) do
          Branchproof::CLI.new(stdout: stdout, stderr: stderr).call(
            ["analyze", "--project", "rails", "--format", "json", "--level", "3", "--test", "test/fixture_rails_test.rb", "--", "--seed", "12345"]
          )
        end
        refute_empty stdout.string, stderr.string
        report = JSON.parse(stdout.string)

        assert_equal 0, exit_code, stderr.string
        assert_equal "PASSED", report.dig("baseline", "status"), stderr.string
        assert_equal "rails", report.dig("baseline", "project", "kind")
        assert_match(/\A8\.1\./, report.dig("baseline", "project", "rails_version"))
        assert_equal 1, report.dig("baseline", "project", "serial_policy", "workers")
        assert_equal 12_345, report.dig("baseline", "seed")
        assert_operator report.dig("metrics", "eligible_conditions"), :>, 0
        refute_empty report.fetch("analysis")
        proven = report.fetch("analysis").fetch("decisions").flat_map { |decision| decision.fetch("condition_results") }
        assert(proven.any? { |condition| condition.fetch("status") == "PROVEN" })
        observations = report.fetch("observations")
        assert(observations.fetch("tests").all? { |test| test.fetch("phase_counts").values_at("setup", "body", "teardown").all? { |count| count == 1 } })
        assert(observations.fetch("vectors").any? { |vector| vector.fetch("values").include?(true) && vector.fetch("values").include?(false) && vector.fetch("phases_by_test").values.flatten.include?("body") })
        service_test = observations.fetch("tests").find { |test| test.fetch("method_name").include?("service") }
        refute_nil service_test
        service_phases = observations.fetch("vectors").flat_map { |vector| vector.fetch("phases_by_test").fetch(service_test.fetch("id"), []) }
        assert_includes service_phases, "setup"
        assert_includes service_phases, "body"
        assert_includes service_phases, "teardown"
        assert_equal 1, File.read(File.join(root, "tmp", "test_helper_loads")).lines.length
        assert_equal "1", File.read(File.join(root, "tmp", "bootsnap_loaded"))
        report.fetch("baseline").fetch("tests").each do |test|
          assert_operator test.dig("phase_counts", "setup"), :>=, 1
          assert_operator test.dig("phase_counts", "body"), :>=, 1
          assert_operator test.dig("phase_counts", "teardown"), :>=, 1
        end
        assert_equal before, application_source(root)
      ensure
        previous ? ENV["BRANCHPROOF_FIXTURE_EAGER"] = previous : ENV.delete("BRANCHPROOF_FIXTURE_EAGER")
      end
    end
  end

  def test_real_rails_failure_returns_failed_exit_status
    unless ENV["BRANCHPROOF_RAILS_INTEGRATION"] == "1"
      skip "set BRANCHPROOF_RAILS_INTEGRATION=1 to run the Rails integration"
    end

    Dir.mktmpdir("branchproof-rails-failure-") do |root|
      copy_fixture(root)
      File.write(File.join(root, "test", "failure_test.rb"), <<~RUBY)
        require "test_helper"
        class FixtureFailureTest < ActiveSupport::TestCase
          test "fails" do
            flunk "intentional integration failure"
          end
        end
      RUBY
      previous = ENV.fetch("BRANCHPROOF_FIXTURE_EAGER", nil)
      ENV["BRANCHPROOF_FIXTURE_EAGER"] = "0"
      stdout = StringIO.new
      stderr = StringIO.new
      exit_code = Dir.chdir(root) do
        Branchproof::CLI.new(stdout: stdout, stderr: stderr).call(
          ["analyze", "--project", "rails", "--format", "json", "--level", "1", "--test", "test/failure_test.rb"]
        )
      end
      report = JSON.parse(stdout.string)

      assert_equal 1, exit_code, stderr.string
      assert_equal "FAILED", report.dig("baseline", "status")
      assert_equal 1, report.dig("baseline", "failed_tests")
    ensure
      previous ? ENV["BRANCHPROOF_FIXTURE_EAGER"] = previous : ENV.delete("BRANCHPROOF_FIXTURE_EAGER")
    end
  end

  def test_real_rails_reloading_is_rejected
    unless ENV["BRANCHPROOF_RAILS_INTEGRATION"] == "1"
      skip "set BRANCHPROOF_RAILS_INTEGRATION=1 to run the Rails integration"
    end

    Dir.mktmpdir("branchproof-rails-reload-") do |root|
      copy_fixture(root)
      application = File.join(root, "config", "application.rb")
      File.write(application, File.read(application).sub("config.enable_reloading = false", "config.enable_reloading = true"))
      stdout = StringIO.new
      stderr = StringIO.new
      exit_code = Dir.chdir(root) do
        Branchproof::CLI.new(stdout: stdout, stderr: stderr).call(
          ["analyze", "--project", "rails", "--format", "json", "--level", "1", "--test", "test/fixture_rails_test.rb"]
        )
      end
      report = JSON.parse(stdout.string)

      assert_equal 2, exit_code
      assert_equal "ERROR", report.dig("baseline", "status")
      assert_includes report.fetch("diagnostics").map { |diagnostic| diagnostic.fetch("message") }.join(" "), "reloading"
    end
  end

  def test_real_rails_name_filter_selects_one_test
    unless ENV["BRANCHPROOF_RAILS_INTEGRATION"] == "1"
      skip "set BRANCHPROOF_RAILS_INTEGRATION=1 to run the Rails integration"
    end

    Dir.mktmpdir("branchproof-rails-name-") do |root|
      copy_fixture(root)
      stdout = StringIO.new
      stderr = StringIO.new
      exit_code = Dir.chdir(root) do
        Branchproof::CLI.new(stdout: stdout, stderr: stderr).call(
          ["analyze", "--project", "rails", "--format", "json", "--level", "1", "--test", "test/fixture_rails_test.rb", "--", "--name", "/controller_through_Zeitwerk\\z/", "--seed", "54321"]
        )
      end
      report = JSON.parse(stdout.string)

      assert_equal 0, exit_code, stderr.string
      assert_equal "PASSED", report.dig("baseline", "status")
      assert_equal 1, report.dig("baseline", "executed_tests")
      assert_equal 54_321, report.dig("baseline", "seed")
      assert_equal 1, File.read(File.join(root, "tmp", "test_helper_loads")).lines.length
    end
  end

  private

  def copy_fixture(root)
    FileUtils.cp_r(Dir[File.join(FIXTURE, "*")], root)
  end

  def application_source(root)
    Dir.glob(File.join(root, "{app,config}/**/*.rb")).to_h do |path|
      [path.delete_prefix("#{root}/"), File.binread(path)]
    end
  end
end
