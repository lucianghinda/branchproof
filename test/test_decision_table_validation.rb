# frozen_string_literal: true

require "test_helper"
require "branchproof/saved_report"

class TestDecisionTableValidation < Minitest::Test
  def test_accepts_current_table_and_legacy_report_without_a_table
    assert_equal current_document, Branchproof::SavedReport.new(current_document).validate!

    legacy = current_document
    legacy["schema_version"] = "1.2"
    legacy["analysis"]["decisions"][0].delete("decision_table")
    assert_equal legacy, Branchproof::SavedReport.new(legacy).validate!
  end

  def test_rejects_tampered_rule_identity_evidence_counts_and_statuses
    cases = [
      ->(document) { document.dig("analysis", "decisions", 0, "decision_table", "rules", 0)["id"] = "foreign" },
      ->(document) { document.dig("analysis", "decisions", 0, "decision_table", "rules", 0)["conditions"] = ["false"] },
      ->(document) { document.dig("analysis", "decisions", 0, "decision_table")["missing_rules"] = 1 },
      ->(document) { document.dig("analysis", "decisions", 0, "decision_table")["reachability_analyzed"] = "yes" },
      ->(document) { document.dig("analysis", "decisions", 0, "decision_table", "rules", 0)["vector_ids"] = ["missing"] },
      ->(document) { document.dig("analysis", "decisions", 0, "decision_table", "rules", 0)["outcome"] = false }
    ]

    cases.each do |change|
      document = current_document
      change.call(document)
      assert_raises(ArgumentError) { Branchproof::SavedReport.new(document).validate! }
    end
  end

  def test_accepts_a_calculated_table_without_reachability_analysis_when_no_rules_are_excluded
    document = current_document
    table = document.dig("analysis", "decisions", 0, "decision_table")
    table["reachability_analyzed"] = false
    assert_equal document, Branchproof::SavedReport.new(document).validate!
  end

  def test_rejects_future_table_and_solver_versions
    [
      ->(document) { document.dig("analysis", "decisions", 0, "decision_table")["schema_version"] = 2 },
      ->(document) { document.dig("analysis", "decisions", 0, "decision_table")["constraint_analysis_version"] = 3 }
    ].each do |change|
      document = current_document
      change.call(document)
      error = assert_raises(ArgumentError) { Branchproof::SavedReport.new(document).validate! }
      assert_match(/unsupported .*version/, error.message)
    end
  end

  def test_rejects_evidence_on_missing_or_excluded_rules_even_when_counts_are_adjusted
    document = current_document
    table = document.dig("analysis", "decisions", 0, "decision_table")
    rule = table.fetch("rules").first
    rule["coverage"] = "missing"
    rule["reachability"] = "unknown"
    table["covered_rules"] = 0
    table["missing_rules"] = 1
    table["coverage_status"] = "unexecuted"
    table["percentage"] = 0.0
    error = assert_raises(ArgumentError) { Branchproof::SavedReport.new(document).validate! }
    assert_match(/noncovered.*evidence/, error.message)
  end

  def test_rejects_mismatched_table_decision_and_rule_metadata
    [
      ->(document) { document.dig("analysis", "decisions", 0, "decision_table")["decision_id"] = "other" },
      ->(document) { document.dig("analysis", "decisions", 0, "decision_table", "rules", 0)["index"] = -1 },
      ->(document) { document.dig("analysis", "decisions", 0, "decision_table", "rules", 0)["label"] = "R2" }
    ].each do |change|
      document = current_document
      change.call(document)
      assert_raises(ArgumentError) { Branchproof::SavedReport.new(document).validate! }
    end
  end

  private

  def current_document
    conditions = [{ "id" => "condition-1", "index" => 0, "expression" => "ready" }]
    decision_id = "decision-1"
    vector_id = "vector-1"
    rule_id = Branchproof::DecisionTable.rule_id(decision_id, ["true"], true)
    rule = { "id" => rule_id, "label" => "R1", "index" => 0, "conditions" => ["true"], "outcome" => true,
             "coverage" => "covered", "reachability" => "observed", "reachability_reason" => nil,
             "tests" => ["test-1"], "vector_ids" => [vector_id], "unattributed_count" => 0 }
    table = { "status" => "calculated", "reason" => nil, "schema_version" => 1,
              "constraint_analysis_version" => 2, "decision_id" => decision_id, "rules" => [rule], "generated_rules" => 1,
              "impossible_rules" => 0, "required_rules" => 1, "covered_rules" => 1, "missing_rules" => 0,
              "coverage_status" => "covered", "percentage" => 100.0, "reachability_analyzed" => true,
              "diagnostics" => [] }
    {
      "schema_version" => "1.3", "tool_version" => "0.7.0", "criterion_version" => "masking_occurrence_v1",
      "runtime" => "ruby", "run_ids" => ["run-1"],
      "source_inventory" => { "source_units" => [{ "source_id" => "source-1", "relative_path" => "lib/example.rb",
                                                   "digest" => "digest" }],
                              "decisions" => [{ "id" => decision_id, "source_id" => "source-1", "expression" => "ready",
                                                "line" => 1, "conditions" => conditions }] },
      "baseline" => { "status" => "PASSED", "finalized" => true },
      "observations" => { "tests" => [{ "id" => "test-1", "name" => "ExampleTest#test_ready" }],
                          "vectors" => [{ "id" => vector_id, "decision_id" => decision_id, "values" => [true],
                                          "outcome" => true, "test_ids" => ["test-1"], "unattributed_count" => 0 }],
                          "completeness" => { "observation" => true, "attribution" => true, "analysis" => true } },
      "analysis" => { "proven_count" => 0, "eligible_count" => 1,
                      "decisions" => [{ "decision_id" => decision_id, "condition_results" => [
                        { "condition_id" => "condition-1", "status" => "NOT_PROVEN" }
                      ], "decision_table" => table }],
                      "completeness" => { "observation" => true, "attribution" => true, "analysis" => true } },
      "minima" => [], "metrics" => {}, "diagnostics" => [],
      "completeness" => { "observation" => true, "attribution" => true, "analysis" => true }
    }
  end
end
