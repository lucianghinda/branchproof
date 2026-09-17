# frozen_string_literal: true

require "test_helper"
require "branchproof/analyzer"
require "branchproof/report"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

class TestDecisionTableReporting < Minitest::Test
  SOURCE = <<~RUBY
    def allowed?(premium, admin, owner)
      premium && (admin || owner)
    end

    def window?(age)
      age && false
    end
  RUBY

  def setup
    @root = Dir.mktmpdir("branchproof-decision-table-")
    FileUtils.mkdir_p(File.join(@root, "lib"))
    File.binwrite(File.join(@root, "lib", "policy.rb"), SOURCE)
    @inventory = Branchproof::Source.new(root: @root, limits: Branchproof::Limits.default)
                                    .inventory(paths: ["lib/policy.rb"])
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def decisions = @inventory[:decisions].select { |decision| decision[:kind] == "boolean" }
  def access_decision = decisions.find { |decision| decision[:expression].include?("premium") }
  def window_decision = decisions.find { |decision| decision[:expression].include?("age") }

  # Records one completed observation per entry as the runtime would.
  def evidence_for(observations)
    evidence = Branchproof::Evidence.new(inventory: @inventory, limits: Branchproof::Limits.default,
                                         run_id: "run-1")
    observations.map { |entry| entry[:test] }.uniq.each do |name|
      evidence.register_test(test: { id: name, adapter: "minitest", name: name, class_name: "PolicyTest",
                                     method_name: name, phase_counts: {} })
    end
    observations.each do |entry|
      status = evidence.record(execution: { run_id: "run-1", decision_id: entry[:decision][:id],
                                            test_id: entry[:test], phase: "body",
                                            observations: entry[:values].each_with_index
                                                                        .filter_map do |value, index|
                                                                          [index, value] unless value.nil?
                                                                        end,
                                            outcome: entry[:outcome], status: "completed" })
      assert_equal "recorded", status[:status], status[:reason]
    end
    evidence.snapshot
  end

  def default_observations
    [{ decision: access_decision, test: "test_free", values: [false, nil, nil], outcome: false },
     { decision: access_decision, test: "test_admin", values: [true, true, nil], outcome: true },
     { decision: access_decision, test: "test_denied", values: [true, false, false], outcome: false },
     { decision: window_decision, test: "test_window", values: [false, nil], outcome: false },
     { decision: window_decision, test: "test_window", values: [true, false], outcome: false }]
  end

  def document(level: 3, missing_only: false, view: :decisions, observations: default_observations)
    snapshot = evidence_for(observations)
    analysis = Branchproof::Analyzer.new(inventory: @inventory, evidence: snapshot,
                                         limits: Branchproof::Limits.default).call
    report = Branchproof::Report.new(
      inventory: @inventory, evidence: snapshot, analysis: analysis, minima: [],
      baseline: { status: "PASSED", executed_tests: 4, failed_tests: 0, skipped_tests: 0, finalized: true },
      diagnostics: [], level: level, missing_only: missing_only, view: view,
      run_metadata: { project_kind: "ruby", project_root: @root, source_patterns: ["lib/**/*.rb"],
                      test_patterns: ["test/**/*_test.rb"], test_files: [], runner_args: [],
                      limits: Branchproof::Limits.default, requested_level: level }
    )
    [report, analysis]
  end

  def render(**)
    report, = document(**)
    io = StringIO.new
    report.write(io: io, format: :terminal)
    io.string
  end

  def json_document(**)
    report, = document(**)
    io = StringIO.new
    report.write(io: io, format: :json)
    JSON.parse(io.string)
  end

  def test_terminal_report_renders_the_reduced_table_with_status_per_rule
    output = render

    assert_includes output, "Decision Table: 3/4 rules covered (75.0%)"
    assert_includes output, "Rule  premium  admin  owner  Result  Status"
    assert_includes output, "R1    F        -      -      F       COVERED"
    assert_includes output, "R2    T        T      -      T       COVERED"
    assert_includes output, "R3    T        F      T      T       MISSING"
    assert_includes output, "R4    T        F      F      F       COVERED"
  end

  def test_terminal_report_attributes_covered_rules_to_minitest_tests
    output = render

    assert_includes output, "R1 tests: PolicyTest#test_free"
    assert_includes output, "R2 tests: PolicyTest#test_admin"
    assert_includes output, "R4 tests: PolicyTest#test_denied"
  end

  def test_missing_rules_describe_condition_values_and_the_expected_decision
    output = render

    assert_includes output, "    Need:\n      premium = truthy\n      admin   = falsey\n      owner   = truthy\n"
    assert_includes output, "    Expected decision:\n      true\n"
    assert_includes output, "    Reachability:\n      unknown\n"
  end

  def test_impossible_rules_stay_visible_and_leave_the_denominator
    output = render

    assert_includes output, "Decision Table: 2/2 rules covered (100.0%)"
    assert_includes output, "Statically impossible rules excluded: 1"
    assert_match(/R3\s+T\s+T\s+T\s+EXCLUDED/, output)
    assert_includes output, "    Status:\n      EXCLUDED\n"
    assert_includes output, "    Reachability:\n      STATICALLY IMPOSSIBLE\n"
    assert_includes output, "    Reason:\n      conflicting Boolean literal requirements\n"
  end

  def test_coverage_ladder_lists_decision_table_separately_from_mcdc
    output = render

    assert_includes output, "DT (Decision table coverage): 83.33% (5/6 rules)"
    assert_includes output, "Decision tables fully covered: 1/2 decisions"
    assert_includes output, "MC/DC=FAIL (2/3 conditions), DT=FAIL (3/4 rules)"
    assert_includes output, "MC/DC=FAIL (0/2 conditions), DT=PASS (2/2 rules)"
  end

  def test_missing_only_view_lists_uncovered_rules_without_impossible_ones
    output = render(missing_only: true)

    assert_includes output, "R3"
    refute_includes output, "EXCLUDED"
    assert_includes output, "decision-table rules: 1"
  end

  def test_decision_tables_view_shows_rules_reachability_and_owners
    output = render(view: :decision_tables)

    assert_includes output, "Branchproof focused view: decision_tables"
    assert_includes output, "R3 TFT => T  MISSING"
    assert_includes output, "Tests: NOT COVERED"
    assert_includes output, "R3 TT => T  EXCLUDED"
    assert_includes output, "Reachability: STATICALLY IMPOSSIBLE"
    assert_includes output, "Reason: conflicting Boolean literal requirements"
    assert_includes output, "1 statically impossible rule excluded"
  end

  def test_decision_tables_missing_only_view_hides_impossible_rules
    output = render(view: :decision_tables, missing_only: true)

    assert_includes output, "R3 TFT => T  MISSING"
    refute_includes output, "EXCLUDED"
    assert_includes output, "1 statically impossible rule excluded"
  end

  def test_json_carries_schema_versions_rules_coverage_and_reachability
    document = json_document
    decision = document.fetch("analysis").fetch("decisions")
                       .find { |item| item.fetch("decision_id") == access_decision[:id] }
    table = decision.fetch("decision_table")

    assert_equal "calculated", table.fetch("status")
    assert_equal 1, table.fetch("schema_version")
    assert_equal Branchproof::Constraints::VERSION, table.fetch("constraint_analysis_version")
    assert_equal %w[false dont_care dont_care], table.fetch("rules").first.fetch("conditions")
    assert_equal "covered", table.fetch("rules").first.fetch("coverage")
    assert_equal "observed", table.fetch("rules").first.fetch("reachability")
    missing = table.fetch("rules").find { |rule| rule.fetch("coverage") == "missing" }
    assert_equal %w[true false true], missing.fetch("conditions")
    assert_equal "unknown", missing.fetch("reachability")
    assert_empty missing.fetch("tests")
    assert_equal %w[covered missing], table.fetch("rules").map { |rule| rule.fetch("coverage") }.uniq.sort
  end

  def test_json_persists_reachability_reasons_for_impossible_rules
    document = json_document
    table = document.fetch("analysis").fetch("decisions")
                    .find { |item| item.fetch("decision_id") == window_decision[:id] }
                    .fetch("decision_table")
    excluded = table.fetch("rules").find { |rule| rule.fetch("coverage") == "excluded" }

    assert_equal "statically_impossible", excluded.fetch("reachability")
    assert_equal "boolean_literal_conflict", excluded.fetch("reachability_reason")
    assert_equal 1, table.fetch("impossible_rules")
    assert_equal 2, table.fetch("required_rules")
  end

  def test_saved_report_validates_and_reopens_the_decision_table_offline
    document = json_document

    assert_equal document, Branchproof::SavedReport.new(document).validate!
    reopened = Branchproof::Report.from_document(document: document, level: 3, view: :decision_tables)
    io = StringIO.new
    reopened.write(io: io, format: :terminal)

    assert_includes io.string, "R3 TFT => T  MISSING"
  end

  def test_saved_report_rejects_a_table_that_contradicts_its_rules
    document = json_document
    table = document.fetch("analysis").fetch("decisions")
                    .find { |item| item.fetch("decision_id") == access_decision[:id] }
                    .fetch("decision_table")
    table["covered_rules"] = 4

    error = assert_raises(ArgumentError) { Branchproof::SavedReport.new(document).validate! }
    assert_includes error.message, "covered_rules mismatch"
  end

  def test_saved_report_rejects_unknown_rule_enum_values
    document = json_document
    table = document.fetch("analysis").fetch("decisions")
                    .find { |item| item.fetch("decision_id") == access_decision[:id] }
                    .fetch("decision_table")
    table.fetch("rules").first["conditions"] = [nil, nil, nil]

    error = assert_raises(ArgumentError) { Branchproof::SavedReport.new(document).validate! }
    assert_includes error.message, "rule conditions do not match the decision"
  end

  def test_comparison_reports_rule_coverage_gained_without_calling_it_an_analysis_change
    before = json_document
    after = json_document(observations: default_observations +
      [{ decision: access_decision, test: "test_owner", values: [true, false, true], outcome: true }])
    result = Branchproof::Comparison.new(before: before, after: after).call
    gained = result.fetch("decision_table_changes").reject { |change| change["change"] == "unchanged" }

    assert_equal 1, gained.length
    assert_equal "rule coverage gained", gained.first.fetch("change")
    assert_equal "uncovered", state(gained.first.fetch("previous"))
    assert_equal "covered", state(gained.first.fetch("current"))
    assert_equal 0, result.fetch("decision_table_regressions")
    assert_equal 7, result.dig("decision_table_matching", "matched_rules")
  end

  def test_comparison_reports_rule_coverage_lost_and_fails_on_regression
    before = json_document
    after = json_document(observations: default_observations.reject { |entry| entry[:test] == "test_denied" })
    result = Branchproof::Comparison.new(before: before, after: after).call
    lost = result.fetch("decision_table_changes").select { |change| change["change"] == "rule coverage lost" }

    assert_equal 1, lost.length
    assert_equal 1, result.fetch("decision_table_regressions")
    rendered = StringIO.new
    report = Branchproof::ComparisonReport.new(document: result)
    report.write(io: rendered, format: :terminal)

    assert_includes rendered.string, "Rule coverage lost:"
    assert_includes rendered.string, "Previous: covered, reachability observed"
    assert_includes rendered.string, "Current: uncovered, reachability unknown"
  end

  def state(entry) = entry.fetch("coverage") == "covered" ? "covered" : "uncovered"
end
