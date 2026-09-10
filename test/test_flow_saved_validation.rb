# frozen_string_literal: true

require "test_helper"
require "branchproof/saved_report"

class TestFlowSavedValidation < Minitest::Test
  def test_schema_1_2_requires_complete_flow_analysis
    document = flow_document
    document["analysis"]["decisions"][0].delete("coverage")

    assert_invalid(document, /requires coverage/)
  end

  def test_schema_1_2_rejects_implicit_trace_without_two_boolean_selections
    document = flow_document(kind: "implicit", values: [[true, false]])
    document["observations"]["vectors"][0]["values"] = [true, nil]

    assert_invalid(document, /flow vector trace/)
  end

  def test_schema_1_2_rejects_multiway_trace_that_does_not_end_at_true
    document = flow_document
    document["observations"]["vectors"][1]["values"] = [true, false]

    assert_invalid(document, /flow vector trace/)
  end

  def test_schema_1_2_rejects_malformed_flow_coverage_as_argument_error
    document = flow_document
    document["analysis"]["decisions"][0]["coverage"] = []

    assert_invalid(document, /flow coverage must be an object/)
  end

  def test_schema_1_2_reconciles_alternative_evidence_with_vectors_and_owners
    document = flow_document
    selected = document["analysis"]["decisions"][0]["coverage"]["alternative"]["alternatives"][0]["selected"]
    selected["vector_ids"] = ["v1"]
    selected["test_ids"] = ["t1"]

    assert_invalid(document, /state mismatch|incomplete|another decision|owners mismatch/)

    document = flow_document
    selected = document["analysis"]["decisions"][0]["coverage"]["alternative"]["alternatives"][0]["selected"]
    selected["vector_ids"] = %w[v0 v0]
    assert_invalid(document, /duplicate alternative evidence vector/)
  end

  def test_schema_1_2_reconciles_counts_and_missing_ids
    document = flow_document
    coverage = document["analysis"]["decisions"][0]["coverage"]["alternative"]
    coverage["covered_alternatives"] = -1
    assert_invalid(document, /nonnegative/)

    document = flow_document
    coverage = document["analysis"]["decisions"][0]["coverage"]["alternative"]
    coverage["covered_alternatives"] = 1
    coverage["missing_alternatives"] = []
    assert_invalid(document, /missing alternatives do not match|covered alternatives do not match/)
  end

  def test_legacy_schema_keeps_permissive_flow_shapes
    document = flow_document
    document["schema_version"] = "1.1"
    document["observations"]["vectors"][1]["values"] = [true, false]
    document["analysis"]["decisions"][0].delete("coverage")

    assert_equal document, Branchproof::SavedReport.new(document).validate!
  end

  def test_unsupported_flow_keeps_unsupported_result_contract
    document = flow_document
    decision = document["source_inventory"]["decisions"][0]
    decision["support_status"] = "UNSUPPORTED"
    document["observations"]["vectors"][0]["values"] = [false, false]
    analysis = document["analysis"]["decisions"][0]
    analysis["coverage"] = {
      "alternative" => { "status" => "unsupported", "covered_alternatives" => 0,
                         "required_alternatives" => 0, "alternatives" => [], "missing_alternatives" => [] },
      "mcdc" => { "status" => "unsupported" }
    }

    assert_equal document, Branchproof::SavedReport.new(document).validate!
  end

  private

  def assert_invalid(document, message)
    error = assert_raises(ArgumentError) { Branchproof::SavedReport.new(document).validate! }
    assert_match(message, error.message)
  end

  def flow_document(kind: "multiway", values: [[true, nil], [false, true]])
    alternatives = [
      { "id" => "a", "index" => 0, "expression" => "first" },
      { "id" => "b", "index" => 1, "expression" => "second" }
    ]
    vectors = values.each_with_index.map do |vector, index|
      { "id" => "v#{index}", "decision_id" => "flow", "values" => vector,
        "outcome" => true, "test_ids" => ["t#{index}"], "unattributed_count" => 0 }
    end
    rows = alternatives.each_with_index.map do |alternative, index|
      states = { "selected" => [], "not_selected" => [], "skipped" => [] }
      vectors.each do |vector|
        value = vector["values"][index]
        state = if value.nil?
                  "skipped"
                else
                  (value ? "selected" : "not_selected")
                end
        states[state] << vector
      end
      evidence = states.transform_values do |items|
        { "observed" => !items.empty?, "vector_ids" => items.map { |item| item["id"] },
          "test_ids" => items.flat_map { |item| item["test_ids"] }.uniq,
          "unattributed_count" => 0 }
      end
      { "alternative_id" => alternative["id"], "index" => index, "expression" => alternative["expression"] }.merge(evidence)
    end
    {
      "schema_version" => "1.2", "tool_version" => "test", "criterion_version" => "masking_occurrence_v1",
      "runtime" => "ruby", "run_ids" => ["run"],
      "source_inventory" => { "source_units" => [{ "source_id" => "source", "relative_path" => "flow.rb", "digest" => "digest" }],
                              "decisions" => [{ "id" => "flow", "source_id" => "source", "kind" => kind,
                                                "expression" => "flow", "conditions" => [], "tree" => nil,
                                                "alternatives" => alternatives }] },
      "baseline" => { "status" => "PASSED", "finalized" => true },
      "observations" => { "tests" => [{ "id" => "t0", "name" => "test0" }, { "id" => "t1", "name" => "test1" }],
                          "vectors" => vectors, "completeness" => { "observation" => true, "attribution" => true, "analysis" => true } },
      "analysis" => { "decisions" => [{ "decision_id" => "flow", "condition_results" => [],
                                        "coverage" => { "alternative" => { "status" => "covered", "covered_alternatives" => 2,
                                                                           "required_alternatives" => 2, "alternatives" => rows,
                                                                           "missing_alternatives" => [] },
                                                        "mcdc" => { "status" => "not_applicable" } } }],
                      "completeness" => { "observation" => true, "attribution" => true, "analysis" => true } },
      "minima" => [], "metrics" => {}, "diagnostics" => [],
      "completeness" => { "observation" => true, "attribution" => true, "analysis" => true }
    }
  end
end
