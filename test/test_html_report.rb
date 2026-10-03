# frozen_string_literal: true

require "test_helper"
require "branchproof/report"
require "stringio"
require_relative "support/summary_document"

class TestHtmlReport < Minitest::Test
  include SummaryDocument

  def render(document = summary_document, level: 3, missing_only: false, selection: Branchproof::ReportSelection.new)
    coordinator = Branchproof::Report.from_document(document: document, level: level)
    Branchproof::HtmlReport.new(document: document, level: level, coordinator: coordinator,
                                missing_only: missing_only, selection: selection).render
  end

  def test_renders_ranked_file_navigation_and_decision_details_with_local_ordinals
    html = render(level: 1)

    assert_includes html, "<nav aria-label=\"Source files\">"
    assert_match(%r{lib/b\.rb.*unexecuted}, html)
    assert_operator html.index("p &amp;&amp; q"), :<, html.index("left &amp;&amp; right")
    assert_match(/href="#decision-\d+"/, html)
    assert_match(/id="decision-\d+"/, html)
    html.scan(/href="#([^"]+)"/).flatten.each do |anchor|
      assert_includes html, "id=\"#{anchor}\""
    end
    refute_includes html, "Cases to test"
  end

  def test_level_two_shows_missing_scenarios_and_excluded_decision_table_denominator
    document = summary_document
    table = document[:analysis][:decisions].find { |row| row[:decision_id] == "unexecuted" }[:decision_table]
    table[:generated_rules] = 4
    table[:impossible_rules] = 1
    table[:required_rules] = 3

    html = render(document, level: 2)

    assert_includes html, "Cases to test: 3"
    assert_includes html, "R1 [TT]"
    assert_includes html, "NOT_PROVEN"
    assert_includes html, "Excluded"
    assert_includes html, "impossible"
    refute_includes html, "ATest#test_both"
  end

  def test_level_three_labels_contributing_tests_separately_from_proof
    html = render(level: 3)

    assert_includes html, "Tests reaching this decision"
    assert_includes html, "Contributing tests"
    assert_includes html, "ATest#test_both"
    assert_includes html, "Proof owner"
  end

  def test_top_applies_to_global_ranked_decisions_before_files_are_grouped
    html = render(level: 1, selection: Branchproof::ReportSelection.new(top: 1))

    assert_includes html, "3 ranked decisions hidden"
    assert_includes html, "lib/b.rb"
    refute_includes html, "lib/a.rb"
  end

  def test_missing_only_hides_decisions_without_known_gaps
    html = render(level: 1, missing_only: true)

    refute_includes html, "x &amp;&amp; y"
    assert_includes html, "left &amp;&amp; right"
  end

  def test_unsupported_count_is_labeled_run_wide_under_focus
    html = render(level: 1, selection: Branchproof::ReportSelection.new(focus: "lib/a.rb"))

    assert_includes html, "2 supported decisions in this selection"
    assert_includes html, "Unsupported decisions: 1 (not ranked; MC/DC unavailable) (run-wide)."
    refute_includes html, "legacy"
  end

  def test_hostile_snapshot_text_is_escaped_and_never_becomes_markup
    document = summary_document
    document[:source_inventory][:source_units].first[:relative_path] = "lib/<script>alert(1)</script>.rb"
    document[:source_inventory][:decisions].first[:expression] = "<img src=x onerror=alert(1)>"
    document[:observations][:tests].first[:method_name] = "test_<b>hostile</b>"
    document[:diagnostics] = [{ code: "hostile", message: "<script>diagnostic</script>" }]

    html = render(document)

    assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert_includes html, "&lt;img src=x onerror=alert(1)&gt;"
    assert_includes html, "&lt;b&gt;hostile&lt;/b&gt;"
    refute_match(/<script|<img|<b>/, html)
  end

  def test_analysis_unavailable_keeps_inventory_without_inventing_gaps
    html = render(summary_document(analysis: false), level: 1)

    assert_includes html, "Analysis unavailable"
    assert_includes html, "lib/a.rb"
    refute_includes html, "Cases to test"
    refute_includes html, "No missing coverage"
  end

  def test_analysis_unavailable_top_limits_inventory_and_creates_no_broken_links
    html = render(summary_document(analysis: false), level: 1,
                                                     selection: Branchproof::ReportSelection.new(top: 1))

    assert_includes html, "4 inventory decisions hidden"
    assert_equal 2, html.scan("analysis unavailable").length
    assert_empty html.scan(/href="#decision-\d+"/)
  end

  def test_focus_and_keyboard_scrolling_are_available_in_the_integrated_layout
    html = render(level: 2, selection: Branchproof::ReportSelection.new(focus: "lib/a.rb"))

    assert_includes html, "Focus: lib/a.rb"
    assert_includes html, "tabindex=\"0\" role=\"region\""
    assert_includes html, ".table-wrap:focus-visible"
    labels = html.scan(/role="region" aria-label="([^"]+)"/).flatten
    assert_equal labels.uniq, labels
  end

  def test_not_calculated_decision_table_keeps_its_reason
    document = summary_document
    partial = document[:analysis][:decisions].find { |row| row[:decision_id] == "partial" }
    partial[:decision_table] = { status: "not_calculated", reason: "condition limit" }

    html = render(document, level: 2)

    assert_includes html, "Decision table: not_calculated. Reason: condition limit."
  end

  def test_long_scenario_tokens_can_wrap_within_the_mobile_viewport
    document = summary_document
    decision = document[:source_inventory][:decisions].find { |row| row[:id] == "unexecuted" }
    token = "INFEASIBLE_IN_MODEL_" * 12
    decision[:conditions].first[:expression] = token

    html = render(document, level: 2)

    assert_includes html, token
    assert_match(/body\{[^}]*overflow-wrap:anywhere/, html)
  end

  def test_decision_table_preserves_unknown_reachability_and_excluded_rule_reason
    document = summary_document
    table = document[:analysis][:decisions].find { |row| row[:decision_id] == "unexecuted" }[:decision_table]
    table[:reachability_analyzed] = false
    table[:rules].first[:reachability] = "unknown"
    table[:rules].first[:reachability_reason] = "<script>not assessed</script>"
    table[:rules] << { label: "RX", conditions: %w[true false], outcome: true, coverage: "excluded",
                       reachability: "statically_impossible", reachability_reason: "contradictory_constraints" }

    html = render(document, level: 2)

    assert_includes html, "Reachability analysis: not analyzed"
    assert_includes html, "UNKNOWN"
    assert_includes html, "STATICALLY IMPOSSIBLE (excluded from denominator)"
    assert_includes html, "&lt;script&gt;not assessed&lt;/script&gt;"
    assert_includes html, "contradictory constraints"
    refute_match(/<script>/, html)
  end

  def test_incomplete_run_and_empty_selection_keep_lower_bound_and_unknown_states
    document = summary_document(status: "FAILED")
    document[:baseline][:finalized] = false
    document[:completeness][:attribution] = false
    selection = Branchproof::ReportSelection.new(decision_ids: [])

    html = render(document, level: 2, selection: selection)

    assert_includes html, "lower bounds"
    assert_includes html, "not established"
  end

  def test_report_dispatches_html_format
    report = Branchproof::Report.from_document(document: summary_document, level: 1)
    output = StringIO.new

    report.write(io: output, format: :html)

    assert_includes output.string, "<!doctype html>"
    assert_includes Branchproof::Report::FORMATS, :html
  end
end
