# frozen_string_literal: true

require "test_helper"
require "branchproof/coverage_index"

class TestCoverageIndex < Minitest::Test
  def index
    @index ||= Branchproof::CoverageIndex.new(document: document)
  end

  def document
    {
      source_inventory: { source_units: [{ source_id: "source", relative_path: "lib/decision.rb" }],
                          decisions: [{ id: "decision", source_id: "source", expression: "left && right",
                                        conditions: [{ id: "left", index: 0, expression: "left", line: 2, column: 6 },
                                                     { id: "right", index: 1, expression: "right", line: 2, column: 13 }] }] },
      observations: { tests: [test_record("both", 10), test_record("false", 15), test_record("short", 20),
                              test_record("unobserved", 25)],
                      vectors: [{ id: "tt", decision_id: "decision", values: [true, true], outcome: true,
                                  test_ids: %w[both], phases_by_test: { "both" => %w[setup body] }, count: 1 },
                                { id: "tf", decision_id: "decision", values: [true, false], outcome: false,
                                  test_ids: %w[false both], phases_by_test: { "false" => ["body"], "both" => ["teardown"] }, count: 1 },
                                { id: "fn", decision_id: "decision", values: [false, nil], outcome: false,
                                  test_ids: %w[short], phases_by_test: { "short" => ["body"] }, count: 1 },
                                { id: "ua", decision_id: "decision", values: [true, false], outcome: false,
                                  test_ids: [], unattributed_count: 1, count: 1 }] },
      analysis: { decisions: [{ decision_id: "decision", condition_results: [
        { condition_id: "left", status: "NOT_PROVEN", canonical_pair: nil },
        { condition_id: "right", status: "PROVEN", canonical_pair: %w[tt tf] }
      ] }] },
      minima: [{ objective: "tests", scope_decision_ids: ["decision"], selected_ids: %w[both false], status: "EXACT_MINIMUM" }]
    }
  end

  def test_indexes_boolean_short_circuit_and_unattributed_evidence
    right = index.conditions.find { |row| row[:id] == "right" }
    left = index.conditions.find { |row| row[:id] == "left" }

    assert_equal ["both"], right[:observed_true]
    assert_equal %w[both false], right[:observed_false]
    assert_equal ["short"], right[:short_circuited]
    assert_equal 1, right[:unattributed]
    assert_equal ["short"], left[:observed_false]
    assert_empty left[:witness_owners]
  end

  def test_resolves_each_witness_owner_and_preserves_phases
    right = index.conditions.find { |row| row[:id] == "right" }
    both = index.tests.find { |row| row[:id] == "both" }

    assert_equal ["DecisionTest#test_both", "DecisionTest#test_false"], right[:witness_owners]
    assert_equal %w[body setup teardown], both[:phases]
    assert_equal true, both[:observations].find { |row| row[:condition_id] == "right" }[:value]
    assert_equal 4, index.tests.length
  end

  def test_does_not_invent_observations_or_proof_for_unobserved_tests
    left = index.conditions.find { |row| row[:id] == "left" }
    unobserved = index.tests.find { |row| row[:id] == "unobserved" }

    assert_equal "NOT_PROVEN", left[:status]
    assert_equal ["short"], left[:observed_false]
    assert_empty unobserved[:observations]
    refute unobserved[:owns_witness]
  end

  def test_legacy_and_saved_locations_never_fall_back_to_absolute_paths
    snapshot = document
    test = snapshot[:observations][:tests].first
    test[:source] = { path: "/old/project/test/decision_test.rb", line: 10 }
    unknown = Branchproof::CoverageIndex.new(document: snapshot).tests.find { |row| row[:id] == "both" }
    assert_nil unknown[:relative_path]
    snapshot[:run_metadata] = { project_root: "/old/project" }
    relocated = Branchproof::CoverageIndex.new(document: snapshot).tests.find { |row| row[:id] == "both" }
    assert_equal "test/decision_test.rb", relocated[:relative_path]
    test[:source][:path] = "/old/shared/external_test.rb"
    outside = Branchproof::CoverageIndex.new(document: snapshot).tests.find { |row| row[:id] == "both" }
    assert_equal "../shared/external_test.rb", outside[:relative_path]
  end

  def test_masks_do_not_change_observation_groups_and_document_is_unchanged
    snapshot = document
    snapshot[:analysis][:decisions].first[:effective_masks_by_vector] = { "tt" => 0 }
    original = Marshal.dump(snapshot)
    row = Branchproof::CoverageIndex.new(document: snapshot).conditions.find { |condition| condition[:id] == "right" }
    assert_equal ["both"], row[:observed_true]
    assert_equal original, Marshal.dump(snapshot)
  end

  private

  def test_record(name, line)
    { id: name, class_name: "DecisionTest", method_name: "test_#{name}", source: { relative_path: "test/decision_test.rb", line: line } }
  end
end
