# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class DecisionTableAcceptanceTest < Minitest::Test
  GEM_ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.join(GEM_ROOT, "exe", "branchproof")

  SOURCE = <<~RUBY
    def allowed?(premium, admin, owner)
      premium && (admin || owner)
    end

    def window?(age)
      File.write(ENV.fetch("BRANCHPROOF_COUNTER"), "x", mode: "a")
      age > 10 && age < 5
    end
  RUBY

  TEST_SOURCE = <<~RUBY
    class PolicyTest < Minitest::Test
      def test_free_user
        refute allowed?(false, true, true)
      end

      def test_admin
        assert allowed?(true, true, false)
      end

      def test_denied
        refute allowed?(true, false, false)
      end

      def test_window
        refute window?(3)
        refute window?(20)
      end
    end
  RUBY

  def test_one_run_produces_tables_reachability_and_attribution
    result = run_project

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    report = result.fetch(:json)
    access = boolean_decision(report, "premium")
    table = decision_table(report, access)

    assert_equal "calculated", table.fetch("status")
    assert_equal 1, table.fetch("schema_version")
    assert_equal 4, table.fetch("generated_rules")
    assert_equal 3, table.fetch("covered_rules")
    assert_equal 4, table.fetch("required_rules")
    assert_in_delta 75.0, table.fetch("percentage")
    signatures = table.fetch("rules").map { |rule| [rule.fetch("conditions"), rule.fetch("outcome")] }

    assert_equal [[%w[false dont_care dont_care], false], [%w[true true dont_care], true],
                  [%w[true false true], true], [%w[true false false], false]], signatures
    covered = table.fetch("rules").first

    assert_equal %w[test_free_user], owner_method_names(report, covered.fetch("tests"))
    assert_equal "observed", covered.fetch("reachability")
    missing = table.fetch("rules")[2]

    assert_equal "missing", missing.fetch("coverage")
    assert_equal "unknown", missing.fetch("reachability")
    assert_empty missing.fetch("tests")
  end

  def test_static_impossibility_is_conservative_and_excluded_from_the_denominator
    result = run_project

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    report = result.fetch(:json)
    table = decision_table(report, boolean_decision(report, "age"))
    excluded = table.fetch("rules").find { |rule| rule.fetch("coverage") == "excluded" }

    assert_equal %w[true true], excluded.fetch("conditions")
    assert_equal "statically_impossible", excluded.fetch("reachability")
    assert_equal "conflicting_numeric_bounds", excluded.fetch("reachability_reason")
    assert_equal 3, table.fetch("generated_rules")
    assert_equal 2, table.fetch("required_rules")
    assert_equal 2, table.fetch("covered_rules")
    assert_equal "covered", table.fetch("coverage_status")
  end

  def test_aggregate_keeps_rule_coverage_and_decision_coverage_distinct
    report = run_project.fetch(:json)
    aggregate = report.fetch("analysis").fetch("coverage").fetch("decision_table")

    assert_equal 2, aggregate.fetch("decisions_analyzed")
    assert_equal 1, aggregate.fetch("fully_covered_decisions")
    assert_equal 5, aggregate.fetch("covered_rules")
    assert_equal 6, aggregate.fetch("required_rules")
    assert_equal 1, aggregate.fetch("impossible_rules")
    assert_in_delta 83.33, aggregate.fetch("percentage")
    assert_in_delta 50.0, aggregate.fetch("decision_percentage")
  end

  def test_decision_table_analysis_does_not_rerun_the_suite
    result = run_project

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    # `window?` is called twice by the single `test_window` body.
    assert_equal 2, result.fetch(:invocations)
    assert_equal 4, result.fetch(:json).fetch("baseline").fetch("executed_tests")
  end

  def test_decision_tables_view_renders_missing_rules_only
    result = run_project(format: "terminal", extra: ["--view", "decision-tables", "--missing-only", "--level", "3"])

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    assert_includes result.fetch(:stdout), "Branchproof focused view: decision_tables"
    assert_includes result.fetch(:stdout), "R3 TFT => T  MISSING"
    assert_includes result.fetch(:stdout), "1 statically impossible rule excluded"
    refute_includes result.fetch(:stdout), "EXCLUDED"
  end

  def test_unknown_view_is_a_usage_error
    result = run_project(format: "terminal", extra: ["--view", "rules"])

    assert_equal 2, result[:status].exitstatus
    assert_includes result.fetch(:stderr), "view must be decisions, conditions, tests, or decision-tables"
  end

  def test_condition_limit_marks_the_table_not_calculated
    limits = { "max_conditions_for_decision_table" => 2 }
    result = run_project(limits: limits)

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    report = result.fetch(:json)
    table = decision_table(report, boolean_decision(report, "premium"))

    assert_equal "not_calculated", table.fetch("status")
    assert_equal "decision_table_condition_limit_exceeded", table.fetch("reason")
    assert_empty table.fetch("rules")
    assert_equal 1, report.fetch("analysis").fetch("coverage").fetch("decision_table")
                          .fetch("not_calculated_decisions")
  end

  def test_saved_report_round_trips_the_table_offline
    Dir.mktmpdir("branchproof-decision-table-saved-") do |directory|
      saved = File.join(directory, "report.json")
      result = run_project(format: "json", extra: ["--output", saved])

      assert_equal 0, result[:status].exitstatus, result[:stderr]
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, EXECUTABLE, "report", saved,
                                              "--view", "decision-tables", "--level", "3")

      assert_equal 0, status.exitstatus, stderr
      assert_includes stdout, "Decision Table:"
      assert_includes stdout, "Reachability: STATICALLY IMPOSSIBLE"
    end
  end

  private

  def boolean_decision(report, needle)
    report.fetch("source_inventory").fetch("decisions").find do |decision|
      decision.fetch("kind", "boolean") == "boolean" && decision.fetch("expression").include?(needle)
    end
  end

  def decision_table(report, decision)
    report.fetch("analysis").fetch("decisions")
          .find { |item| item.fetch("decision_id") == decision.fetch("id") }
          .fetch("decision_table")
  end

  def owner_method_names(report, test_ids)
    report.fetch("observations").fetch("tests").select { |test| test_ids.include?(test.fetch("id")) }
          .map { |test| test.fetch("method_name") }
  end

  def run_project(format: "json", extra: [], limits: nil)
    Dir.mktmpdir("branchproof-decision-table-acceptance-") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      source_path = File.join(root, "lib", "policy.rb")
      test_path = File.join(root, "test", "policy_test.rb")
      counter = File.join(root, "counter")
      File.binwrite(source_path, SOURCE)
      File.binwrite(test_path, "require #{source_path.inspect}\nrequire \"minitest/autorun\"\n#{TEST_SOURCE}")
      File.binwrite(counter, "")
      arguments = ["analyze", source_path, "--format", format, "--test", test_path, *extra]
      if limits
        limits_path = File.join(root, "limits.json")
        File.binwrite(limits_path, JSON.generate(limits))
        arguments += ["--limits", limits_path]
      end
      env = { "MT_NO_PLUGINS" => "1", "BRANCHPROOF_COUNTER" => counter }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, EXECUTABLE, *arguments, chdir: root)
      parsed = format == "json" && status.exitstatus.zero? && !extra.include?("--output") ? JSON.parse(stdout) : nil
      { root: root, stdout: stdout, stderr: stderr, status: status, json: parsed,
        invocations: File.exist?(counter) ? File.read(counter).length : nil }
    end
  end
end
