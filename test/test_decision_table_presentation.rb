# frozen_string_literal: true

require "test_helper"
require "json"
require "branchproof/coverage_index"
require "branchproof/focused_report"
require "branchproof/report"

class TestDecisionTablePresentation < Minitest::Test
  Coordinator = Struct.new(:ladder) do
    def coverage_ladder_lines = Array(ladder)
    def coverage_policy_lines = []
    def diagnostic_message(diagnostic) = diagnostic[:message].to_s
    def decision_table_requirement(value) = { "true" => "truthy", "false" => "falsey" }[value.to_s]
    def decision_table_reachability(rule) = rule[:reachability].to_s
    def decision_table_expected_heading(_row) = "Expected decision:"
  end

  def test_missing_only_keeps_an_uncalculated_table_visible
    output = focused_document(
      decision_table: {
        status: "not_calculated", reason: "decision_table_condition_limit_exceeded", rules: []
      }
    )

    assert_includes output, "Decision: flag"
    assert_includes output, "Location: lib/policy.rb:4"
    assert_includes output, "Decision Table: NOT CALCULATED"
    assert_includes output, "Reason: decision_table_condition_limit_exceeded"
    refute_includes output, "No missing decision-table rules"

    output = focused_document(
      decision_table: {
        status: "not_calculated", reason: "decision_table_rule_limit_exceeded", rules: []
      }
    )
    assert_includes output, "Reason: decision_table_rule_limit_exceeded"
  end

  def test_report_missing_only_explains_unavailable_analysis
    report = Branchproof::Report.from_document(
      document: report_document(
        decision_table: { status: "not_calculated", reason: "decision_table_condition_limit_exceeded", rules: [] }
      ), level: 3, missing_only: true
    )
    io = StringIO.new
    report.write(io: io, format: :terminal)

    assert_includes io.string, "Decision Table: NOT CALCULATED"
    assert_includes io.string, "decision-table analysis unavailable for 1 decision"
  end

  def test_predicate_labels_are_used_in_full_and_focused_reports
    %w[unless until].each do |context|
      document = report_document(
        context: context, expression: "flag", decision_table: calculated_missing_table
      )
      full = Branchproof::Report.from_document(document: document, level: 3, missing_only: true)
      full_io = StringIO.new
      full.write(io: full_io, format: :terminal)
      focused = Branchproof::FocusedReport.new(document: document, view: :decision_tables, level: 3,
                                               missing_only: true).render

      assert_includes full_io.string, "Predicate true: observed"
      assert_includes full_io.string, "Expected predicate:"
      assert_includes focused, "Expected predicate: true"
    end
  end

  def test_decision_tables_are_lazy_and_accept_saved_string_keys
    document = JSON.parse(JSON.generate(report_document(
                                          decision_table: { status: "not_calculated",
                                                            reason: "decision_table_condition_limit_exceeded", rules: [] }
                                        )))
    index = Branchproof::CoverageIndex.new(document: document)

    assert_nil index.instance_variable_get(:@decision_tables)
    assert_equal "not_calculated", index.decision_tables.first[:status]
    refute_nil index.instance_variable_get(:@decision_tables)
  end

  def test_focused_report_marks_disabled_reachability
    output = focused_document(
      decision_table: calculated_missing_table.merge(reachability_analyzed: false)
    )

    assert_includes output, "Reachability: not analyzed"
  end

  private

  def focused_document(decision_table:)
    Branchproof::FocusedReport.new(document: report_document(decision_table: decision_table), view: :decision_tables, level: 3,
                                   missing_only: true, coordinator: Coordinator.new([])).render
  end

  def calculated_missing_table
    { status: "calculated", rules: [{ label: "R1", index: 0, conditions: ["true"], outcome: true,
                                      coverage: "missing", reachability: "unknown", tests: [], vector_ids: [],
                                      unattributed_count: 0 }], generated_rules: 1, impossible_rules: 0,
      required_rules: 1, covered_rules: 0, missing_rules: 1, coverage_status: "partial",
      reachability_analyzed: true }
  end

  def report_document(decision_table:, context: "if", expression: "flag")
    decision_coverage = {
      outcomes: [{ value: true, observed: true, test_ids: [], unattributed_count: 0 }], missing_outcomes: []
    }
    {
      source_inventory: {
        root: "/tmp/project", source_units: [{ source_id: "source", relative_path: "lib/policy.rb", digest: "x" }],
        decisions: [{ id: "decision", source_id: "source", kind: "boolean", expression: expression, line: 4,
                      context: context, conditions: [{ id: "condition", index: 0, expression: expression, line: 4, column: 4 }],
                      alternatives: [] }]
      },
      observations: { vectors: [], tests: [] }, baseline: { status: "PASSED" },
      analysis: { coverage: {}, completeness: { observation: true, attribution: true, analysis: true },
                  decisions: [{ decision_id: "decision", condition_results: [],
                                coverage: { decision: decision_coverage },
                                decision_table: decision_table }] },
      completeness: { observation: true, attribution: true, analysis: true }, diagnostics: []
    }
  end
end
