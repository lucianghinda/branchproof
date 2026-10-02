# frozen_string_literal: true

require "test_helper"
require "branchproof/report"
require "stringio"
require_relative "support/summary_document"

class TestGithubReport < Minitest::Test
  include SummaryDocument

  def report(document = summary_document, level: 3, **)
    Branchproof::Report.from_document(document: document, level: level, **)
  end

  def annotations(document = summary_document, **)
    output = StringIO.new
    report(document, **).write(io: output, format: :github)
    output.string.lines(chomp: true)
  end

  def test_warnings_follow_summary_rank_with_file_and_line
    warnings = annotations.grep(/\A::warning /)

    assert_equal(["lib/b.rb,line=5", "lib/a.rb,line=2", "lib/c.rb,line=3"],
                 warnings.map { |line| line[/file=([^,]+,line=\d+)/, 1] })
    assert warnings.first.start_with?("::warning file=lib/b.rb,line=5,title=Branchproof #1%3A unexecuted; " \
                                      "DT 3/3 rules missing; MC/DC 2/2 conditions unproven::p && q%0A")
  end

  def test_warning_message_lists_cases_to_test
    warning = annotations.find { |line| line.include?("file=lib/a.rb") }

    assert_includes warning, "%0ACases to test: 1%0AR2 [TF]: left truthy, right falsey; expected decision false"
  end

  def test_notice_closes_output_with_ladder_and_gap_count
    notice = annotations.last

    assert notice.start_with?("::notice title=Branchproof coverage::")
    assert_includes notice, "MC/DC (MC/DC coverage): 50.0%25 (3/6 conditions)"
    assert_includes notice, "%0ADecisions with gaps: 3"
    assert_includes notice, "%0AUnsupported decisions: 1 (not ranked)"
  end

  def test_top_limits_warnings_and_notice_counts_hidden_gaps
    lines = annotations(top: 1)

    assert_equal 1, lines.grep(/\A::warning /).length
    assert_includes lines.last, "%0ANot annotated (--top): 2"
  end

  def test_failed_tests_become_an_error
    assert_includes annotations(summary_document(status: "FAILED")), "::error title=Branchproof tests::Tests FAILED"
  end

  def test_error_and_warning_diagnostics_become_escaped_annotations
    document = summary_document(status: "ERROR")
    document[:diagnostics] = [
      { code: "unsupported_runner", severity: "error", source_id: "a",
        message: "parallel test scheduling is unsupported\n::warning file=evil,title=injected::bad" },
      { code: "runner_notice", severity: "warning", message: "runner used fallback" },
      { code: "runner_info", severity: "info", message: "runner detected" }
    ]

    lines = annotations(document)
    error = lines.find { |line| line.start_with?("::error title=Branchproof diagnostic") }
    warning = lines.find { |line| line.start_with?("::warning title=Branchproof diagnostic") }
    notice = lines.find { |line| line.start_with?("::notice title=Branchproof diagnostic") }

    assert_equal "::error title=Branchproof diagnostic (unsupported_runner)::" \
                 "lib/a.rb: parallel test scheduling is unsupported%0A::warning file=evil,title=injected::bad", error
    assert_equal "::warning title=Branchproof diagnostic (runner_notice)::runner used fallback", warning
    assert_equal "::notice title=Branchproof diagnostic (runner_info)::runner detected", notice
    diagnostic_errors = lines.grep(/\A::error title=Branchproof diagnostic/)
    assert_equal 1, diagnostic_errors.length
  end

  def test_step_summary_includes_error_and_warning_diagnostics
    document = summary_document(status: "ERROR")
    document[:diagnostics] = [
      { code: "unsupported_runner", severity: "error", source_id: "a",
        message: "parallel test scheduling is unsupported" },
      { code: "runner_notice", severity: "warning", message: "runner used fallback" },
      { code: "runner_info", severity: "info", message: "runner detected" }
    ]

    markdown = report(document).step_summary

    assert_includes markdown, "### Diagnostics"
    assert_includes markdown, "- **ERROR (unsupported_runner):** `lib/a.rb: parallel test scheduling is unsupported`"
    assert_includes markdown, "- **WARNING (runner_notice):** `runner used fallback`"
    assert_includes markdown, "- **INFO (runner_info):** `runner detected`"
  end

  def test_failed_policy_gates_become_errors
    lines = annotations(minimum: { "mcdc" => 90 })

    assert_includes lines, "::error title=Branchproof coverage policy::mcdc: 3/6, threshold 90"
    refute_includes lines.join, "Branchproof tests"
  end

  def test_workflow_command_values_are_escaped
    document = summary_document
    document[:source_inventory][:source_units][1][:relative_path] = "lib/b,1:x.rb"
    document[:source_inventory][:decisions][2][:expression] = "p % 2 && q"
    warning = annotations(document).grep(/\A::warning /).first

    assert warning.start_with?("::warning file=lib/b%2C1%3Ax.rb,line=5,")
    assert_includes warning, "::p %25 2 && q%0A"
  end

  def test_github_output_keeps_exit_status
    document = summary_document
    options = { minimum: { "mcdc" => 90 } }

    assert_equal report(document, **options).exit_code, report(document, view: :summary, **options).exit_code
    assert_equal 1, report(document, **options).exit_code
  end

  def test_step_summary_has_ladder_policy_and_ranked_table
    markdown = report(minimum: { "mcdc" => 90 }).step_summary

    assert_includes markdown, "## Branchproof coverage"
    assert_includes markdown, "**Tests:** PASSED"
    assert_includes markdown, "- MC/DC (MC/DC coverage): 50.0% (3/6 conditions)"
    assert_includes markdown, "| mcdc | 3/6 | 90 | FAILED |"
    assert_includes markdown, "| 1 | `lib/b.rb:5` | `p && q` | unexecuted; DT 3/3 rules missing; " \
                              "MC/DC 2/2 conditions unproven | 3 |"
    assert_operator markdown.index("`lib/b.rb:5`"), :<, markdown.index("`lib/a.rb:2`")
  end

  def test_step_summary_escapes_table_pipes
    document = summary_document
    document[:source_inventory][:decisions][2][:expression] = "p || q"

    assert_includes report(document).step_summary, "`p \\|\\| q`"
  end

  def test_step_summary_caps_rows_and_counts_the_rest
    markdown = report(top: 2).step_summary

    assert_includes markdown, "`lib/a.rb:2`"
    refute_includes markdown, "`lib/c.rb:3`"
    assert_includes markdown, "1 more decision with gaps not shown."
  end

  def test_step_summary_without_analysis_says_ranking_is_unavailable
    markdown = report(summary_document(analysis: false), level: 1).step_summary

    assert_includes markdown, "Ranking unavailable: the report has no analysis."
  end

  def test_unavailable_policy_gates_become_errors_with_reason
    document = summary_document
    document[:analysis][:coverage][:decision_table] = { status: "not_calculated" }
    lines = annotations(document, minimum: { "mcdc" => 10, "decision_table" => 50 })
    error = lines.find { |line| line.include?("decision_table") }

    assert error.start_with?("::error title=Branchproof coverage policy::decision_table: ")
    assert_includes error, "unavailable; reason: "
    refute(lines.any? { |line| line.include?("mcdc: 3/6") })
  end

  def test_incomplete_passed_run_becomes_an_error
    document = summary_document
    document[:completeness][:analysis] = false

    assert_includes annotations(document),
                    "::error title=Branchproof run::Run incomplete; coverage counts are lower bounds"
  end

  def test_notice_says_ranking_is_unavailable_without_analysis
    notice = annotations(summary_document(status: "FAILED", analysis: false), level: 1).last

    assert_includes notice, "Ranking unavailable: the report has no analysis"
    refute_includes notice, "Decisions with gaps"
  end

  def test_path_prefix_makes_annotation_paths_repository_relative
    output = StringIO.new
    report.write(io: output, format: :github, path_prefix: "gems/tool/")

    assert_includes output.string, "::warning file=gems/tool/lib/b.rb,line=5,"
  end

  def test_github_report_constructor_prefix_remains_the_annotation_default
    document = summary_document
    renderer = Branchproof::GithubReport.new(document: document, level: 3,
                                             coordinator: report(document), path_prefix: "gems/tool/")

    assert_includes renderer.annotations, "::warning file=gems/tool/lib/b.rb,line=5,"
  end

  def test_annotations_reuse_the_step_summary_renderer_with_each_call_prefix
    renderer = report
    summary_before = renderer.step_summary
    nested = StringIO.new
    renderer.write(io: nested, format: :github, path_prefix: "gems/tool/")
    summary_after = renderer.step_summary
    root = StringIO.new
    renderer.write(io: root, format: :github)

    assert_equal summary_before, summary_after
    assert_includes nested.string, "::warning file=gems/tool/lib/b.rb,line=5,"
    assert_includes root.string, "::warning file=lib/b.rb,line=5,"
    refute_includes root.string, "gems/tool/lib/b.rb"
  end

  def test_step_summary_reuse_does_not_pin_an_annotation_prefix
    renderer = report
    root = StringIO.new
    renderer.write(io: root, format: :github)
    summary = renderer.step_summary
    nested = StringIO.new
    renderer.write(io: nested, format: :github, path_prefix: "gems/other")

    assert_includes root.string, "::warning file=lib/b.rb,line=5,"
    assert_includes nested.string, "::warning file=gems/other/lib/b.rb,line=5,"
    assert_includes summary, "`lib/b.rb:5`"
    refute_includes summary, "gems/other"
  end

  def test_step_summary_code_span_is_longer_than_inner_backticks
    document = summary_document
    document[:source_inventory][:decisions][2][:expression] = "a == `x``y` && b"

    assert_includes report(document).step_summary, "``` a == `x``y` && b ```"
  end

  def test_step_summary_policy_table_shows_gate_reason
    document = summary_document
    document[:analysis][:coverage][:decision_table] = { status: "not_calculated" }
    markdown = report(document, minimum: { "decision_table" => 50 }).step_summary

    assert_match(%r{\| decision_table \| N/A \| 50 \| UNAVAILABLE \| \w+ \|}, markdown)
  end

  def test_any_other_nonzero_exit_status_gets_a_generic_error
    lines = annotations

    assert_equal 2, report.exit_code
    assert_equal "::error title=Branchproof::Exit status 2; see the terminal report diagnostics", lines.first
  end
end
