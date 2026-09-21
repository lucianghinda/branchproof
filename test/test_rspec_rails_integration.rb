# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "json"
require "stringio"
require "tmpdir"
require "branchproof/rails_support"

class TestRSpecRailsIntegration < Minitest::Test
  FIXTURE = File.expand_path("fixtures/rspec_rails_app", __dir__).freeze

  def test_focused_pure_ruby_spec_in_detected_rails_project_does_not_require_rails_boot
    with_fixture do |root|
      File.write(File.join(root, "spec", "spec_helper.rb"), "require 'rspec/expectations'\n")
      File.write(File.join(root, "spec", "unit_spec.rb"), <<~RUBY)
        require "spec_helper"
        RSpec.describe "pure Ruby unit" do
          it("passes without Rails") { expect(defined?(Rails)).to be_nil }
        end
      RUBY
      stdout = StringIO.new
      stderr = StringIO.new
      exit_code = Dir.chdir(root) do
        Branchproof::CLI.new(stdout: stdout, stderr: stderr).call(
          ["analyze", "--framework", "rspec", "--format", "json", "--test", "spec/unit_spec.rb"]
        )
      end

      assert_equal 0, exit_code, stderr.string
      report = JSON.parse(stdout.string)
      assert_equal "PASSED", report.dig("baseline", "status")
      assert_equal "rails", report.dig("baseline", "project", "kind")
      assert_equal 1, report.dig("baseline", "executed_tests")
      refute File.exist?(File.join(root, "tmp", "environment_loads"))
    end
  end

  def test_rspec_driver_policy_allows_rack_test_and_rejects_browser_or_threaded_execution
    assert Branchproof::RailsSupport.validate_rspec_driver!(driver: :rack_test)

    %i[selenium rack_test].each do |driver|
      metadata = driver == :rack_test ? { driver: driver, js: true } : { driver: driver }
      error = assert_raises(Branchproof::RailsSupport::Error) do
        Branchproof::RailsSupport.validate_rspec_driver!(metadata)
      end
      assert_includes error.message, "only in-process rack_test"
    end

    assert_raises(Branchproof::RailsSupport::Error) do
      Branchproof::RailsSupport.validate_rspec_driver!(threaded: true)
    end
  end

  def test_driver_guard_does_not_load_capybara_for_non_browser_apps
    skip "Capybara is already loaded by this process" if defined?(Capybara)

    Branchproof::RailsSupport.install_rspec_driver_guard!

    refute defined?(Capybara)
  end

  def test_real_rails_fixture_runs_native_rspec_suite
    unless ENV["BRANCHPROOF_RSPEC_RAILS_INTEGRATION"] == "1"
      skip "set BRANCHPROOF_RSPEC_RAILS_INTEGRATION=1 to run the Rails/RSpec integration"
    end

    [false, true].each do |eager|
      Dir.mktmpdir("branchproof-rspec-rails-") do |root|
        FileUtils.cp_r(Dir[File.join(FIXTURE, "*")], root)
        env = {
          "RAILS_ENV" => "test",
          "BRANCHPROOF_RSPEC_FIXTURE_DB" => File.join(root, "tmp", "test.sqlite3"),
          "BRANCHPROOF_FIXTURE_EAGER" => eager ? "1" : "0"
        }
        command = ["bundle", "exec", "rspec", "--format", "progress", "spec"]
        stdout, stderr, status = Dir.chdir(root) { Open3.capture3(env, *command) }

        assert status.success?, "native RSpec failed (eager=#{eager}):\n#{stdout}\n#{stderr}"
        assert_match(/examples, 0 failures/, stdout)
        refute File.exist?(File.join(root, "db", "development.sqlite3"))
      end
    end
  end

  def test_instrumented_cli_runs_all_rails_rspec_types_in_lazy_and_eager_modes
    integration_only!

    [false, true].each do |eager|
      with_fixture do |root|
        before = application_source(root)
        report, stderr, exit_code = run_instrumented(root, eager: eager)

        assert_equal 0, exit_code, stderr
        assert_equal "PASSED", report.dig("baseline", "status"), stderr
        assert_equal 14, report.dig("baseline", "executed_tests")
        assert_equal "rails", report.dig("baseline", "project", "kind")
        assert_equal "8.1.3.1", report.dig("baseline", "project", "rails_version")
        assert_equal "8.0.4", report.dig("baseline", "project", "rspec_rails_version")
        assert_equal 1, File.readlines(File.join(root, "tmp", "environment_loads")).length
        assert_equal 1, File.readlines(File.join(root, "tmp", "rails_helper_loads")).length
        refute_includes File.read(File.join(root, "spec", "rails_helper.rb")), "rails/test_help"
        refute_match(/Minitest/, stderr)
        assert_equal before, application_source(root)
      end
    end
  end

  def test_rspec_reports_support_all_levels_views_and_repeated_comparison
    integration_only!

    with_fixture do |root|
      first, stderr, exit_code = run_instrumented(root, eager: false, level: 3)
      assert_equal 0, exit_code, stderr
      assert first.key?("analysis")

      report_path = File.join(root, "tmp", "first-report.json")
      File.write(report_path, JSON.generate(first))
      %w[decisions conditions tests decision-tables].each do |view|
        output = StringIO.new
        error = StringIO.new
        status = Branchproof::CLI.new(stdout: output, stderr: error).call(
          ["report", report_path, "--format", "terminal", "--view", view]
        )
        assert_equal 0, status, error.string
        refute_empty output.string
      end

      second, second_stderr, second_exit = run_instrumented(root, eager: false, level: 2)
      assert_equal 0, second_exit, second_stderr
      second_path = File.join(root, "tmp", "second-report.json")
      File.write(second_path, JSON.generate(second))
      output = StringIO.new
      error = StringIO.new
      status = Branchproof::CLI.new(stdout: output, stderr: error).call(
        ["compare", report_path, second_path, "--format", "terminal"]
      )
      assert_equal 0, status, error.string
    end
  end

  def test_instrumented_service_vectors_keep_exact_lifecycle_owners_and_transactions
    integration_only!

    with_fixture do |root|
      report, stderr, exit_code = run_instrumented(root, eager: false, test_glob: "spec/services/fixture_record_service_spec.rb")
      assert_equal 0, exit_code, stderr
      assert_equal "PASSED", report.dig("baseline", "status"), stderr
      assert_equal 2, report.dig("baseline", "executed_tests")

      tests = report.fetch("observations").fetch("tests")
      assert_equal 2, tests.length
      tests.each do |test|
        assert_equal({ "setup" => 2, "body" => 2, "teardown" => 2 }, test.fetch("phase_counts"))
      end

      test_ids = tests.map { |test| test.fetch("id") }
      vectors = report.fetch("observations").fetch("vectors").select do |vector|
        Array(vector.fetch("test_ids")).intersect?(test_ids)
      end
      refute_empty vectors
      vectors.each do |vector|
        owners = vector.fetch("phases_by_test")
        assert_equal vector.fetch("test_ids").sort, owners.keys.sort
        owners.each_value { |phases| assert(phases.intersect?(%w[setup body teardown])) }
      end
      phases = vectors.flat_map { |vector| vector.fetch("phases_by_test").values.flatten }.uniq
      assert_equal %w[body setup teardown], phases.sort
    end
  end

  def test_instrumented_cli_rejects_browser_and_selenium_specs_before_launch
    integration_only!

    with_fixture do |root|
      FileUtils.mkdir_p(File.join(root, "spec", "unsupported"))
      File.write(File.join(root, "spec", "unsupported", "browser_spec.rb"), <<~RUBY)
        require "rails_helper"
        RSpec.describe "browser feature", type: :feature, js: true do
          it { visit "/" }
        end
      RUBY
      File.write(File.join(root, "spec", "unsupported", "selenium_spec.rb"), <<~RUBY)
        require "rails_helper"
        RSpec.describe "selenium system", type: :system, driver: :selenium do
          it { visit "/" }
        end
      RUBY

      report, stderr, exit_code = run_instrumented(root, eager: false, test_glob: "spec/unsupported/**/*_spec.rb")
      assert_equal 2, exit_code
      assert_equal "ERROR", report.dig("baseline", "status")
      assert_match(/unsupported|rack_test/i, JSON.generate(report) + stderr)
    end
  end

  def test_native_and_instrumented_failures_rollback_body_and_hook_writes
    integration_only!

    with_fixture do |root|
      rollback_spec = File.join(root, "spec", "rollback_spec.rb")
      File.write(rollback_spec, <<~RUBY)
        require "rails_helper"

        RSpec.describe "transaction rollback", type: :model do
          it "fails after writing in the body" do
            FixtureRecord.create!(name: "body-failure")
            expect(false).to eq(true)
          end

          it "sees no body write from the previous example" do
            expect(FixtureRecord.count).to eq(0)
          end

          context "with a failing before hook" do
            before do
              FixtureRecord.create!(name: "before-failure")
              raise "before hook failure"
            end

            it("fails before the body") { expect(true).to eq(true) }
          end

          it "sees no before write from the previous example" do
            expect(FixtureRecord.count).to eq(0)
          end

          context "with a failing after hook" do
            after do
              FixtureRecord.create!(name: "after-failure")
              raise "after hook failure"
            end

            it("fails after the body") { expect(true).to eq(true) }
          end

          it "sees no after write from the previous example" do
            expect(FixtureRecord.count).to eq(0)
          end
        end
      RUBY

      env = {
        "RAILS_ENV" => "test",
        "BRANCHPROOF_RSPEC_FIXTURE_DB" => File.join(root, "tmp", "test.sqlite3")
      }
      stdout, stderr, status = Dir.chdir(root) do
        Open3.capture3(env, "bundle", "exec", "rspec", "--format", "progress", "spec/rollback_spec.rb")
      end
      refute status.success?, "native failure suite unexpectedly passed"
      assert_match(/6 examples, 3 failures/, stdout, stderr)

      report, instrumented_stderr, exit_code = run_instrumented(
        root, eager: false, test_glob: "spec/rollback_spec.rb"
      )
      assert_equal 1, exit_code, instrumented_stderr
      assert_equal "FAILED", report.dig("baseline", "status")
      assert_equal 6, report.dig("baseline", "executed_tests")
      assert_equal 3, report.dig("baseline", "failed_tests")
      assert_empty(report.fetch("observations").fetch("tests").select { |test| test.fetch("status") == "running" })
    end
  end

  def test_reloading_and_boot_failures_are_reported_as_errors
    integration_only!

    with_fixture do |root|
      application = File.join(root, "config", "application.rb")
      File.write(application, File.read(application).sub("config.enable_reloading = false", "config.enable_reloading = true"))
      report, stderr, exit_code = run_instrumented(root, eager: false)
      assert_equal "ERROR", report.dig("baseline", "status"), stderr
      assert_equal 2, exit_code
      refute_empty stderr
    end

    with_fixture do |root|
      environment = File.join(root, "config", "environment.rb")
      File.write(environment, "raise 'fixture boot failure'\n")
      report, stderr, exit_code = run_instrumented(root, eager: false)
      assert_equal "ERROR", report.dig("baseline", "status"), stderr
      assert_equal 2, exit_code
      refute_empty stderr
    end
  end

  private

  def integration_only!
    return if ENV["BRANCHPROOF_RSPEC_RAILS_INTEGRATION"] == "1"

    skip "set BRANCHPROOF_RSPEC_RAILS_INTEGRATION=1 to run the Rails/RSpec integration"
  end

  def with_fixture
    Dir.mktmpdir("branchproof-rspec-rails-") do |root|
      FileUtils.cp_r(Dir[File.join(FIXTURE, "*")], root)
      yield root
    end
  end

  def run_instrumented(root, eager:, test_glob: "spec/**/*_spec.rb", level: 1)
    previous = ENV.fetch("BRANCHPROOF_RSPEC_FIXTURE_DB", nil)
    previous_eager = ENV.fetch("BRANCHPROOF_FIXTURE_EAGER", nil)
    ENV["BRANCHPROOF_RSPEC_FIXTURE_DB"] = File.join(root, "tmp", "test.sqlite3")
    ENV["BRANCHPROOF_FIXTURE_EAGER"] = eager ? "1" : "0"
    stdout = StringIO.new
    stderr = StringIO.new
    exit_code = Dir.chdir(root) do
      Branchproof::CLI.new(stdout: stdout, stderr: stderr).call(
        ["analyze", "--project", "rails", "--format", "json", "--level", level.to_s, "--test", test_glob]
      )
    end
    [JSON.parse(stdout.string), stderr.string, exit_code]
  ensure
    previous ? ENV["BRANCHPROOF_RSPEC_FIXTURE_DB"] = previous : ENV.delete("BRANCHPROOF_RSPEC_FIXTURE_DB")
    previous_eager ? ENV["BRANCHPROOF_FIXTURE_EAGER"] = previous_eager : ENV.delete("BRANCHPROOF_FIXTURE_EAGER")
  end

  def application_source(root)
    Dir.glob(File.join(root, "{app,config,spec}/**/*.rb")).to_h do |path|
      [path.delete_prefix("#{root}/"), File.binread(path)]
    end
  end
end
