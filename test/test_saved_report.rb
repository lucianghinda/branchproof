# frozen_string_literal: true

require "test_helper"
require "branchproof/saved_report"
require "json"
require "tempfile"

class TestSavedReport < Minitest::Test
  def write_document(document)
    file = Tempfile.new(["branchproof-report", ".json"])
    file.write(JSON.generate(document))
    file.close
    yield file.path
  ensure
    file&.unlink
  end

  def valid_document(schema_version: "1.1")
    {
      "schema_version" => schema_version,
      "tool_version" => "0.2.0",
      "criterion_version" => "masking_occurrence_v1",
      "runtime" => "ruby",
      "run_ids" => ["run-1"],
      "source_inventory" => {
        "source_units" => [{ "source_id" => "source-1", "relative_path" => "lib/decision.rb", "digest" => "source-digest" }],
        "decisions" => [{ "id" => "decision-1", "source_id" => "source-1",
                          "conditions" => [{ "id" => "condition-1", "index" => 0 },
                                           { "id" => "condition-2", "index" => 1 },
                                           { "id" => "condition-3", "index" => 2 }] }]
      },
      "baseline" => { "status" => "PASSED", "finalized" => true },
      "observations" => {
        "tests" => [{ "id" => "test-1", "name" => "DecisionTest#test_ready" }],
        "vectors" => [{ "id" => "vector-1", "decision_id" => "decision-1",
                        "values" => [true, false, nil], "outcome" => false,
                        "test_ids" => ["test-1"] },
                      { "id" => "vector-2", "decision_id" => "decision-1", "values" => [false, false, nil],
                        "outcome" => true, "test_ids" => ["test-1"] }],
        "completeness" => { "observation" => true, "attribution" => true, "analysis" => true }
      },
      "analysis" => { "decisions" => [{ "decision_id" => "decision-1",
                                        "condition_results" => [{ "condition_id" => "condition-1",
                                                                  "status" => "PROVEN",
                                                                  "canonical_pair" => %w[vector-1 vector-2] },
                                                                { "condition_id" => "condition-2", "status" => "NOT_PROVEN" },
                                                                { "condition_id" => "condition-3", "status" => "NOT_PROVEN" }] }],
                      "completeness" => { "observation" => true, "attribution" => true, "analysis" => true } },
      "minima" => [],
      "metrics" => {},
      "diagnostics" => [],
      "completeness" => { "observation" => true, "attribution" => true, "analysis" => true }
    }.tap { |doc| doc["run_metadata"] = { "requested_level" => 3 } if schema_version == "1.1" }
  end

  def test_reads_supported_versions_and_preserves_boolean_and_nil_values
    ["1.0", "1.1"].each do |version|
      write_document(valid_document(schema_version: version)) do |path|
        document = Branchproof::SavedReport.read(path)

        assert_equal version, document.fetch("schema_version")
        assert_equal [true, false, nil], document.dig("observations", "vectors", 0, "values")
      end
    end
  end

  def test_accepts_optional_framework_and_rspec_test_metadata
    document = valid_document(schema_version: "1.3")
    document["run_metadata"] = { "framework" => "rspec", "framework_version" => nil,
                                 "rspec_rails_version" => "7.2.0", "rails_version" => nil,
                                 "selected_test_files" => ["spec/a_spec.rb"],
                                 "selected_example_ids" => ["./spec/a_spec.rb[1:1]"] }
    document["observations"]["tests"][0].merge!("adapter" => "rspec", "example_id" => "./spec/a_spec.rb[1:1]",
                                                "source" => { "relative_path" => "spec/a_spec.rb", "line" => 1 })

    write_document(document) { |path| assert_equal document, Branchproof::SavedReport.read(path) }
  end

  def test_rejects_malformed_optional_framework_and_selection_metadata
    invalid_documents = [
      valid_document.tap { |doc| doc["run_metadata"] = { "rails_version" => 8.1 } },
      valid_document.tap { |doc| doc["run_metadata"] = { "selected_test_files" => "spec/a_spec.rb" } },
      valid_document.tap { |doc| doc["run_metadata"] = { "selected_example_ids" => ["ok", 1] } }
    ]

    invalid_documents.each do |document|
      write_document(document) { |path| assert_raises(ArgumentError) { Branchproof::SavedReport.read(path) } }
    end
  end

  def test_rejects_unreadable_and_malformed_files_with_argument_error
    assert_raises(ArgumentError) { Branchproof::SavedReport.read("/no/such/report.json") }

    write_document(valid_document) do |path|
      File.write(path, "{\"schema_version\":")
      error = assert_raises(ArgumentError) { Branchproof::SavedReport.read(path) }
      refute_match(/NoMethodError|undefined method/, error.message)
    end
  end

  def test_rejects_wrong_sections_unsupported_schema_and_missing_completeness
    cases = [
      ["unsupported schema", valid_document(schema_version: "2.0").merge("schema_version" => "2.0")],
      ["source inventory", valid_document.merge("source_inventory" => [])],
      ["completeness", valid_document.merge("completeness" => { "observation" => "yes" })]
    ]

    cases.each do |label, document|
      write_document(document) do |path|
        error = assert_raises(ArgumentError, label) { Branchproof::SavedReport.read(path) }
        refute_match(/NoMethodError|undefined method/, error.message)
      end
    end
  end

  def test_rejects_duplicate_ids_and_dangling_references
    duplicate = valid_document
    duplicate["observations"]["tests"] << duplicate["observations"]["tests"].first.dup
    dangling = valid_document
    dangling["observations"]["vectors"][0]["test_ids"] = ["missing-test"]

    [duplicate, dangling].each do |document|
      write_document(document) { |path| assert_raises(ArgumentError) { Branchproof::SavedReport.read(path) } }
    end
  end

  def test_preserves_failed_partial_and_level_one_documents
    document = valid_document.merge("analysis" => nil)
    document["baseline"] = { "status" => "FAILED", "finalized" => false }
    document["completeness"] = { "observation" => false, "attribution" => true, "analysis" => false }
    document["observations"]["completeness"] = document["completeness"]

    write_document(document) do |path|
      assert_equal "FAILED", Branchproof::SavedReport.read(path).dig("baseline", "status")
    end
  end

  def test_rejects_non_boolean_outcomes_and_non_string_hash_keys
    invalid_values = valid_document
    invalid_values["observations"]["vectors"][0]["values"] = [1]
    invalid_keys = valid_document
    invalid_keys["metrics"] = []

    [invalid_values, invalid_keys].each do |document|
      write_document(document) { |path| assert_raises(ArgumentError) { Branchproof::SavedReport.read(path) } }
    end
  end

  def test_rejects_invalid_phase_metadata_vector_arity_and_missing_finalization
    cases = [
      valid_document.tap { |doc| doc["observations"]["vectors"][0]["values"] = [true] },
      valid_document.tap { |doc| doc["observations"]["vectors"][0]["phases_by_test"] = { "missing" => ["body"] } },
      valid_document.tap { |doc| doc["baseline"].delete("finalized") }
    ]

    cases.each do |document|
      write_document(document) { |path| assert_raises(ArgumentError) { Branchproof::SavedReport.read(path) } }
    end
  end

  def test_allows_missing_canonical_pair_for_unproven_condition
    document = valid_document
    result = document["analysis"]["decisions"][0]["condition_results"][0]
    result["status"] = "NOT_PROVEN"
    result["canonical_pair"] = nil

    write_document(document) { |path| assert_equal document, Branchproof::SavedReport.read(path) }
  end

  def test_accepts_legacy_empty_run_and_rejects_nested_renderer_shapes
    legacy = valid_document(schema_version: "1.0").merge("run_ids" => [])
    write_document(legacy) { |path| assert_equal [], Branchproof::SavedReport.read(path).fetch("run_ids") }

    invalid_documents = [
      valid_document.tap { |doc| doc["source_inventory"]["source_units"][0]["relative_path"] = [] },
      valid_document.tap { |doc| doc["observations"]["tests"][0]["source"] = ["bad"] },
      valid_document.tap { |doc| doc["observations"]["tests"][0]["phase_counts"] = { "body" => "one" } },
      valid_document.tap { |doc| doc["minima"] = [{ "selected_ids" => {} }] }
    ]
    invalid_documents.each do |document|
      write_document(document) { |path| assert_raises(ArgumentError) { Branchproof::SavedReport.read(path) } }
    end
  end

  def test_rejects_nested_constraint_shapes_and_inventory_location_types
    changes = [
      ->(doc) { doc["source_inventory"]["decisions"][0]["conditions"][0]["line"] = [] },
      ->(doc) { doc["source_inventory"]["decisions"][0]["conditions"][1]["index"] = 0 },
      ->(doc) { doc["analysis"]["proven_count"] = {} },
      ->(doc) { doc["analysis"]["decisions"][0]["condition_results"][0]["constraint_result"] = [] },
      ->(doc) { doc["baseline"]["tests"] = ["invalid"] },
      ->(doc) { doc["minima"] = [{ "objective" => "tests", "selected_ids" => ["missing"] }] },
      ->(doc) { doc["observations"]["abort_counts"] = { "error" => [] } }
    ]
    changes.each_with_index do |change, index|
      document = valid_document
      change.call(document)
      write_document(document) do |path|
        assert_raises(ArgumentError, "malformed nested case #{index}") { Branchproof::SavedReport.read(path) }
      end
    end
  end

  def test_rejects_ambiguous_source_paths_and_missing_digest
    duplicate = valid_document
    duplicate["source_inventory"]["source_units"] << duplicate["source_inventory"]["source_units"].first.merge("source_id" => "another")
    missing = valid_document
    missing["source_inventory"]["source_units"].first.delete("digest")
    [duplicate, missing].each do |document|
      write_document(document) { |path| assert_raises(ArgumentError) { Branchproof::SavedReport.read(path) } }
    end
  end
end
