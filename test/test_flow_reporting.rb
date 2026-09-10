# frozen_string_literal: true

require "json"
require "stringio"
require "tempfile"
require "test_helper"
require "branchproof/report"
require "branchproof/saved_report"
require "branchproof/coverage_index"

class TestFlowReporting < Minitest::Test
  def test_schema_1_2_accepts_boolean_defaults_and_nonboolean_dimensions
    write_document(report_document) do |path|
      document = Branchproof::SavedReport.read(path)

      assert_equal "1.2", document.fetch("schema_version")
      assert_equal [true, false], document.dig("observations", "vectors", 0, "values")
      assert_equal [true, false], document.dig("observations", "vectors", 1, "values")
      assert_equal "implicit", document.dig("source_inventory", "decisions", 1, "kind")
    end
  end

  def test_roundtrip_and_focused_rendering_show_alternative_evidence
    report = Branchproof::Report.from_document(document: report_document, view: :conditions, level: 3)
    json = StringIO.new
    report.write(io: json, format: :json)
    persisted = JSON.parse(json.string)

    assert_equal "1.2", persisted.fetch("schema_version")
    assert_nil persisted.dig("source_inventory", "decisions", 0, "kind")
    live_json = StringIO.new
    Branchproof::Report.new(inventory: report_document["source_inventory"],
                            evidence: report_document["observations"],
                            analysis: report_document["analysis"],
                            minima: report_document["minima"], baseline: report_document["baseline"],
                            diagnostics: report_document["diagnostics"]).write(io: live_json, format: :json)
    assert_equal "boolean", JSON.parse(live_json.string).dig("source_inventory", "decisions", 0, "kind")
    Branchproof::SavedReport.new(persisted).validate!

    output = StringIO.new
    Branchproof::Report.from_document(document: persisted, view: :conditions, level: 3).write(
      io: output, format: :terminal
    )
    assert_includes output.string, "Kind: implicit"
    assert_includes output.string, "Context: implicit"
    assert_includes output.string, "Alternative 0"
    assert_includes output.string, "Selected by"
    assert_includes output.string, "Missing alternative"
    assert_includes output.string, "Need selection of: b"
    assert_includes output.string, "Alternative coverage: 1/2 alternatives (50.0%)"
    assert_includes output.string, "flow T=selected, F=not-selected, -=skipped"
    refute_includes output.string, "Outcome true"
    assert_equal 0, Branchproof::Report.from_document(document: persisted, level: 3).exit_code

    focused = Branchproof::FocusedReport.new(document: persisted, view: :conditions, level: 3).render
    assert_includes focused, "Alternative 0"
    assert_includes focused, "Selected by"
    assert_includes focused, "MC/DC: N/A"
    assert_includes focused, "Need selection of: b"
  end

  def test_missing_only_keeps_nonboolean_decisions_with_missing_alternatives
    output = Branchproof::Report.from_document(document: report_document, level: 3, missing_only: true).then do |report|
      io = StringIO.new
      report.write(io: io, format: :terminal)
      io.string
    end

    assert_includes output, "Kind: implicit"
    assert_includes output, "Missing alternatives"
    assert_includes output, "Kind: boolean"
  end

  private

  def write_document(document)
    file = Tempfile.new(["branchproof-flow-report", ".json"])
    file.write(JSON.generate(document))
    file.close
    yield file.path
  ensure
    file&.unlink
  end

  def report_document
    {
      "schema_version" => "1.2",
      "tool_version" => "0.7.0",
      "criterion_version" => "masking_occurrence_v1",
      "runtime" => "ruby",
      "run_ids" => ["run-1"],
      "source_inventory" => {
        "source_units" => [{ "source_id" => "source-1", "relative_path" => "lib/flow.rb", "digest" => "digest" }],
        "decisions" => [
          { "id" => "boolean-1", "source_id" => "source-1", "context" => "while",
            "expression" => "ready && enabled", "conditions" => [
              { "id" => "condition-1", "index" => 0, "expression" => "ready" },
              { "id" => "condition-2", "index" => 1, "expression" => "enabled" }
            ] },
          { "id" => "implicit-1", "source_id" => "source-1", "kind" => "implicit", "context" => "implicit",
            "expression" => "left ? a : b", "tree" => nil, "conditions" => [],
            "alternatives" => [
              { "id" => "alternative-1", "index" => 0, "expression" => "a", "line" => 10 },
              { "id" => "alternative-2", "index" => 1, "expression" => "b", "line" => 10 }
            ] }
        ]
      },
      "baseline" => { "status" => "PASSED", "finalized" => true },
      "observations" => {
        "tests" => [
          { "id" => "test-1", "name" => "FlowTest#test_a" },
          { "id" => "test-2", "name" => "FlowTest#test_b" }
        ],
        "vectors" => [
          { "id" => "vector-boolean", "decision_id" => "boolean-1", "values" => [true, false],
            "outcome" => false, "test_ids" => ["test-1"] },
          { "id" => "vector-a", "decision_id" => "implicit-1", "values" => [true, false],
            "outcome" => true, "test_ids" => ["test-1"] }
        ],
        "completeness" => { "observation" => true, "attribution" => true, "analysis" => true }
      },
      "analysis" => {
        "proven_count" => 0, "eligible_count" => 2,
        "decisions" => [
          { "decision_id" => "boolean-1", "condition_results" => [
            { "condition_id" => "condition-1", "status" => "NOT_PROVEN" },
            { "condition_id" => "condition-2", "status" => "NOT_PROVEN" }
          ] },
          { "decision_id" => "implicit-1", "conditions" => [], "condition_results" => [],
            "coverage" => {
              "alternative" => {
                "status" => "partial", "covered_alternatives" => 1, "required_alternatives" => 2,
                "alternatives" => [
                  { "alternative_id" => "alternative-1", "index" => 0, "expression" => "a",
                    "selected" => { "observed" => true, "test_ids" => ["test-1"], "vector_ids" => ["vector-a"],
                                    "unattributed_count" => 0 },
                    "not_selected" => { "observed" => false, "test_ids" => [], "vector_ids" => [],
                                        "unattributed_count" => 0 },
                    "skipped" => { "observed" => false, "test_ids" => [], "vector_ids" => [],
                                   "unattributed_count" => 0 } },
                  { "alternative_id" => "alternative-2", "index" => 1, "expression" => "b",
                    "selected" => { "observed" => false, "test_ids" => [], "vector_ids" => [],
                                    "unattributed_count" => 0 },
                    "not_selected" => { "observed" => true, "test_ids" => ["test-1"], "vector_ids" => ["vector-a"],
                                        "unattributed_count" => 0 },
                    "skipped" => { "observed" => false, "test_ids" => [], "vector_ids" => [],
                                   "unattributed_count" => 0 } }
                ],
                "missing_alternatives" => ["alternative-2"]
              },
              "mcdc" => { "status" => "not_applicable" }
            } }
        ],
        "completeness" => { "observation" => true, "attribution" => true, "analysis" => true },
        "coverage" => {
          "decision" => { "covered_decisions" => 0, "supported_decisions" => 1, "percentage" => 0.0 },
          "condition" => { "covered_values" => 2, "required_values" => 4, "covered_conditions" => 0,
                           "condition_count" => 2, "percentage" => 25.0 },
          "condition_decision" => { "covered_decisions" => 0, "supported_decisions" => 1, "percentage" => 0.0 },
          "mcdc" => { "proven_conditions" => 0, "supported_conditions" => 2, "percentage" => 0.0 },
          "alternative" => { "covered_alternatives" => 1, "required_alternatives" => 2, "percentage" => 50.0 }
        }
      },
      "minima" => [],
      "metrics" => {},
      "diagnostics" => [],
      "completeness" => { "observation" => true, "attribution" => true, "analysis" => true }
    }
  end
end
