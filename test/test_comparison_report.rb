# frozen_string_literal: true

require "test_helper"
require "branchproof/comparison_report"
require "stringio"

class TestComparisonReport < Minitest::Test
  def document(status: "complete", regression: false)
    { "schema_version" => "1.0", "status" => status, "reasons" => [],
      "matching" => { "matched_conditions" => 1, "denominator" => 1 },
      "before" => { "status" => "PASSED" }, "after" => { "status" => "PASSED" },
      "changes" => [{ "change" => "lost proof", "relative_path" => "lib/a.rb", "line" => 3,
                      "index" => 0, "expression" => "flag", "previous_witness" => [{ "tests" => ["A#test_x"] }],
                      "current_witness" => [] }], "changed_sources" => [], "newly_in_report" => [],
      "no_longer_in_report" => [], "regressions" => regression ? 1 : 0, "regression" => regression }
  end

  def test_json_and_terminal_rendering_and_regression_exit
    report = Branchproof::ComparisonReport.new(document: document(regression: true))
    json = StringIO.new
    report.write(io: json, format: :json)
    assert_equal "complete", JSON.parse(json.string).fetch("status")
    terminal = StringIO.new
    report.write(io: terminal, format: :terminal)
    assert_includes terminal.string, "Lost proof: lib/a.rb:3"
    assert_includes terminal.string, "A#test_x"
    assert_equal 1, report.exit_code(fail_on_regression: true)
    assert_equal 0, report.exit_code
  end

  def test_incomplete_comparison_returns_usage_exit
    assert_equal 2, Branchproof::ComparisonReport.new(document: document(status: "comparison incomplete")).exit_code
  end
end
