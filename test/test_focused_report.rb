# frozen_string_literal: true

require "test_helper"
require "branchproof/report"
require "stringio"
require "shellwords"

class TestFocusedReport < Minitest::Test
  def test_rspec_selectors_are_copyable_in_saved_terminal_views
    snapshot = document
    selector = "./spec/policy's shared_spec.rb[1:2]"
    snapshot[:observations][:tests].first.replace(
      id: "tt", name: "shared policy allows access", adapter: "rspec", example_id: selector,
      source: { relative_path: "spec/support/shared.rb", line: 7 }, status: "passed"
    )
    snapshot = JSON.parse(JSON.generate(snapshot))

    %i[decisions conditions tests].each do |view|
      output = StringIO.new
      Branchproof::Report.from_document(document: snapshot, view: view, level: 3)
                         .write(io: output, format: :terminal)
      command = output.string.lines.find { |line| line.include?("bundle exec rspec") }
      refute_nil command, "missing rerun selector in #{view} view"
      command = command[command.index("bundle exec rspec")..].strip
      command = command.delete_suffix(")")
      assert_equal ["bundle", "exec", "rspec", selector], Shellwords.split(command)
    end
  end

  def render(view: :conditions, level: 2, missing_only: false, status: "PASSED")
    report = Branchproof::Report.from_document(document: document(status: status), view: view,
                                               level: level, missing_only: missing_only)
    output = StringIO.new
    report.write(io: output, format: :terminal)
    output.string
  end

  def document(status: "PASSED")
    {
      source_inventory: { source_units: [{ source_id: "s", relative_path: "lib/decision.rb" }],
                          decisions: [{ id: "d", source_id: "s", expression: "left && right",
                                        conditions: [{ id: "l", index: 0, expression: "left", line: 2 },
                                                     { id: "r", index: 1, expression: "right", line: 2 }] }] },
      observations: { tests: [
        { id: "tt", class_name: "DecisionTest", method_name: "test_true", source: { relative_path: "test/d_test.rb", line: 10 }, status: "passed", phase_counts: { "body" => 1 } },
        { id: "tf", class_name: "DecisionTest", method_name: "test_false", source: { relative_path: "test/d_test.rb", line: 15 }, status: "passed", phase_counts: { "setup" => 1, "teardown" => 1 } },
        { id: "skip", class_name: "DecisionTest", method_name: "test_skip", source: { relative_path: "test/d_test.rb", line: 20 }, status: "skipped" }
      ], vectors: [
        { id: "vtt", decision_id: "d", values: [true, true], outcome: true, test_ids: ["tt"], phases_by_test: { "tt" => ["body"] }, count: 1 },
        { id: "vtf", decision_id: "d", values: [true, false], outcome: false, test_ids: ["tf"], phases_by_test: { "tf" => %w[setup teardown] }, count: 1 },
        { id: "vnil", decision_id: "d", values: [false, nil], outcome: false, test_ids: ["tf"], phases_by_test: { "tf" => ["body"] }, count: 1 },
        { id: "vua", decision_id: "d", values: [true, false], outcome: false, test_ids: [], unattributed_count: 1, count: 1 }
      ] },
      analysis: { decisions: [{ decision_id: "d", condition_results: [
        { condition_id: "l", status: "NOT_PROVEN" },
        { condition_id: "r", status: "PROVEN", canonical_pair: %w[vtt vtf] }
      ] }] },
      minima: [{ objective: "tests", scope_decision_ids: ["d"], selected_ids: ["tt"], status: "EXACT_MINIMUM" }],
      baseline: { status: status, finalized: true },
      completeness: { observation: status == "PASSED", attribution: status == "PASSED", analysis: status == "PASSED" }
    }
  end

  def test_condition_view_shows_locations_values_phases_witness_owners_and_unattributed
    output = render(level: 3)

    ["Condition", "Location", "lib/decision.rb:2", "Evaluated true by", "Evaluated false by", "Short-circuited", "Unattributed"].each do |text|
      assert_includes output, text
    end
    assert_includes output, "DecisionTest#test_true"
    assert_includes output, "Witness observations"
    assert_includes output, "Supporting test set"
  end

  def test_test_view_shows_skipped_no_observation_tests_and_phases
    output = render(view: :tests)

    assert_includes output, "Test: DecisionTest#test_true"
    assert_includes output, "Phases: body"
    assert_includes output, "Test: DecisionTest#test_skip"
    assert_includes output, "No recorded completed condition observations"
    assert_includes output, "Unattributed evidence"
  end

  def test_level_one_disables_proof_and_missing_only_filters_proven_rows
    level_one = render(level: 1)
    assert_includes level_one, "MC/DC: NOT CALCULATED"
    refute_includes level_one, "Witness observations"

    missing = render(missing_only: true)
    assert_includes missing, "Condition: left"
    refute_includes missing, "Condition: right"
    assert_includes missing, "Unattributed evidence"
  end

  def test_failed_report_keeps_status_and_incomplete_warning
    output = render(status: "FAILED")

    assert_includes output, "Condition:"
    assert_includes output, "NOT_PROVEN"
    assert_includes output, "failed or incomplete"
  end

  def test_legacy_condition_line_and_unsupported_conditions_are_explicit
    snapshot = document
    snapshot[:source_inventory][:decisions].first[:conditions].first.delete(:line)
    snapshot[:source_inventory][:decisions] << { id: "excluded", source_id: "s", support_status: "UNSUPPORTED",
                                                 expression: "unsupported", conditions: [{ id: "u", index: 0, expression: "unsupported" }] }
    output = Branchproof::FocusedReport.new(document: snapshot, view: :conditions, level: 3).render
    assert_includes output, "lib/decision.rb: condition line unavailable"
    assert_includes output, "Unsupported conditions"
    assert_includes output, "unsupported"
  end

  def test_each_witness_side_names_only_its_actual_owner
    output = render(level: 3)
    true_line = output.lines.find { |line| line.include?("[TT] => T") }
    false_line = output.lines.find { |line| line.include?("[TF] => F") }
    assert_includes true_line, "test_true"
    refute_includes true_line, "test_false"
    assert_includes false_line, "test_false"
    refute_includes false_line, "test_true"
  end

  def test_unexecuted_and_aborted_evidence_remain_visible_in_missing_test_view
    snapshot = document
    snapshot[:observations][:vectors] = []
    snapshot[:observations][:abort_counts] = { error: 2 }
    output = Branchproof::FocusedReport.new(document: snapshot, view: :tests, level: 3, missing_only: true).render
    assert_includes output, "Unexecuted conditions"
    assert_includes output, "2 aborted"
    refute_includes output, "Test: DecisionTest"
  end

  def test_ladder_summary_and_condition_value_evidence_render_in_each_focused_view
    snapshot = Marshal.load(Marshal.dump(document))
    snapshot[:analysis][:coverage] = {
      decision: { covered_decisions: 1, supported_decisions: 1, percentage: 100.0 },
      condition: { covered_values: 3, required_values: 4, covered_conditions: 1, condition_count: 2,
                   percentage: 75.0 },
      condition_decision: { covered_decisions: 0, supported_decisions: 1, percentage: 0.0 },
      mcdc: { proven_conditions: 1, supported_conditions: 2, percentage: 50.0 }
    }
    snapshot[:analysis][:decisions].first[:condition_results].each do |result|
      result[:coverage] = { values: [
        { value: true, observed: true, test_ids: ["tt"] },
        { value: false, observed: false, test_ids: [] }
      ], missing_values: [false] }
    end
    before = Marshal.dump(snapshot)

    %i[conditions tests].each do |view|
      output = Branchproof::FocusedReport.new(document: snapshot, view: view, level: 2).render
      assert_includes output, "Coverage ladder:"
      assert_includes output, "D (Decision coverage): 100.0%"
      assert_includes output, "C (Condition coverage): 75.0%"
      if view == :conditions
        assert_includes output, "Value true: observed; tests: DecisionTest#test_true"
        assert_includes output, "Missing values: false"
      else
        assert_includes output, "Test: DecisionTest#test_true"
      end
    end

    assert_equal before, Marshal.dump(snapshot)
  end
end
