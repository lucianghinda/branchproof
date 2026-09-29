# frozen_string_literal: true

require "test_helper"
require "branchproof/report"
require "stringio"
require_relative "support/summary_document"

class TestSummaryReport < Minitest::Test
  include SummaryDocument

  def render(document = summary_document, level: 3, **)
    output = StringIO.new
    Branchproof::Report.from_document(document: document, view: :summary, level: level, **)
                       .write(io: output, format: :terminal)
    output.string
  end

  def ranked_locations(output)
    output.lines.grep(%r{\A  \d+\. lib/\S+:\d+  }).map { |line| line[%r{lib/\S+:\d+}] }
  end

  def test_unexecuted_decisions_rank_first_then_most_missing_obligations
    output = render

    assert_equal ["lib/b.rb:5", "lib/a.rb:2", "lib/c.rb:3"], ranked_locations(output)
    assert_includes output, "Order: unexecuted decisions first, then most missing obligations"
    assert_includes output, "a count, not a risk estimate"
  end

  def test_fully_covered_decisions_are_not_listed_as_gaps
    refute_includes render, "lib/a.rb:9"
  end

  def test_file_rows_rank_by_unexecuted_then_missing_rules_with_explicit_denominators
    output = render

    assert_includes output, "  1. lib/b.rb: 1/1 decisions with gaps; 1 unexecuted; DT 3/3 rules missing; " \
                            "MC/DC 2/2 conditions unproven"
    assert_includes output, "  2. lib/a.rb: 1/2 decisions with gaps; DT 1/6 rules missing; MC/DC 1/4 conditions unproven"
    assert_includes output, "  3. lib/c.rb: 1/1 decisions with gaps; 1/2 alternatives missing"
  end

  def test_level_two_lists_missing_rules_as_cases_to_test
    output = render(level: 2)

    assert_includes output, "unexecuted; DT 3/3 rules missing; MC/DC 2/2 conditions unproven"
    assert_includes output, "Cases to test: 3"
    assert_includes output, "R2 [TF]: left truthy, right falsey; expected decision false"
    assert_includes output, "Need selection of: String"
    refute_includes output, "Tests reaching this decision"
  end

  def test_level_one_shows_ranked_rows_without_cases
    output = render(level: 1)

    assert_equal ["lib/b.rb:5", "lib/a.rb:2", "lib/c.rb:3"], ranked_locations(output)
    refute_includes output, "Cases to test"
  end

  def test_level_three_names_tests_already_reaching_each_decision
    output = render(level: 3)

    assert_includes output, "Tests reaching this decision: none recorded"
    assert_includes output, "ATest#test_both (test/a_test.rb:10)"
    assert_includes output, "ATest#test_left_false (test/a_test.rb:20)"
  end

  def test_missing_only_hides_fully_covered_files
    document = summary_document
    document[:source_inventory][:source_units] << { source_id: "d", relative_path: "lib/d.rb" }
    document[:source_inventory][:decisions] << boolean_decision("covered_d", "d", 1, "m", "n")
    document[:observations][:vectors] << { id: "vd", decision_id: "covered_d", values: [true, true], outcome: true,
                                           test_ids: ["t_both"] }
    document[:analysis][:decisions] << boolean_analysis("covered_d", proven: [true, true], covered: [true] * 3)

    assert_includes render(document), "lib/d.rb: 0/1 decisions with gaps"
    refute_includes render(document, missing_only: true), "lib/d.rb"
  end

  def test_top_limits_each_ranked_list_and_reports_hidden_counts
    output = render(top: 1)

    assert_equal ["lib/b.rb:5"], ranked_locations(output)
    assert_includes output, "Display limit: top 1 per list; hidden 2 files, 2 decisions"
    refute_includes output, "  2. lib/a.rb"
  end

  def test_focus_limits_ranking_to_matching_decisions
    output = render(focus: "lib/a.rb")

    assert_includes output, "Focus: lib/a.rb"
    assert_equal ["lib/a.rb:2"], ranked_locations(output)
  end

  def test_focus_without_a_match_is_explicit
    output = render(focus: "lib/missing.rb")

    assert_includes output, "Focus: no matching decisions for lib/missing.rb"
    assert_empty ranked_locations(output)
  end

  def test_unsupported_decisions_are_counted_but_not_ranked
    output = render

    assert_includes output, "Unsupported decisions: 1 (not ranked; MC/DC unavailable) (run-wide)"
    refute_includes output, "lib/b.rb:12"
  end

  def test_missing_analysis_reports_ranking_unavailable
    output = render(summary_document(analysis: false), level: 1)

    assert_includes output, "Ranking unavailable: the report has no analysis."
    refute_includes output, "Where to start"
  end

  def test_decision_without_a_calculated_table_lists_unproven_conditions
    document = summary_document
    document[:analysis][:decisions].find { |item| item[:decision_id] == "partial" }[:decision_table] =
      { status: "not_calculated", reason: "too many conditions" }
    output = render(document, level: 2)

    assert_includes output, "Condition 1: right NOT_PROVEN"
  end

  def test_multiline_expressions_render_on_one_line
    document = summary_document
    document[:source_inventory][:decisions].last[:expression] = "case kind\nwhen Integer then 1\nend"

    assert_includes render(document), "lib/c.rb:3  case kind when Integer then 1 end"
  end

  def test_summary_keeps_global_ladder_gates_and_exit_status
    document = summary_document
    options = { level: 3, minimum: { "mcdc" => 90 } }
    decisions = Branchproof::Report.from_document(document: document, view: :decisions, **options)
    summary = Branchproof::Report.from_document(document: document, view: :summary, focus: "lib/c.rb", top: 1,
                                                **options)
    output = StringIO.new
    summary.write(io: output, format: :terminal)

    assert_equal decisions.exit_code, summary.exit_code
    assert_equal 1, summary.exit_code
    assert_includes output.string, "MC/DC (MC/DC coverage): 50.0% (3/6 conditions)"
    assert_includes output.string, "mcdc: 3/6, threshold 90, FAILED"
  end

  def test_files_rank_by_total_missing_obligations_like_decisions
    document = summary_document
    table = document[:analysis][:decisions].find { |item| item[:decision_id] == "partial" }
    table[:decision_table] = { status: "not_calculated", reason: "too many conditions" }
    document[:source_inventory][:decisions] << boolean_decision("wide", "c", 8, "g", "h")
    document[:observations][:vectors] << { id: "vw", decision_id: "wide", values: [true, true], outcome: true,
                                           test_ids: ["t_kind"] }
    document[:analysis][:decisions] << { decision_id: "wide", condition_results: [
      { condition_id: "wide_0", status: "NOT_PROVEN" }, { condition_id: "wide_1", status: "NOT_PROVEN" }
    ], decision_table: { status: "not_calculated", reason: "too many conditions" } }
    files = render(document).lines.grep(%r{\A  \d+\. lib/\w+\.rb: }).map { |line| line[%r{lib/\w+\.rb}] }

    assert_equal ["lib/b.rb", "lib/c.rb", "lib/a.rb"], files
  end

  def test_unproven_conditions_are_listed_when_no_rule_is_missing
    document = summary_document
    partial = document[:analysis][:decisions].find { |item| item[:decision_id] == "partial" }
    partial[:decision_table][:rules][1][:coverage] = "excluded"
    output = render(document, level: 3)

    assert_includes output, "DT 0/3 rules missing; MC/DC 1/2 conditions unproven"
    assert_includes output, "Cases to test: 1"
    assert_includes output, "Condition 1: right NOT_PROVEN"
  end
end
