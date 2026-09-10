# frozen_string_literal: true

require "test_helper"
require "branchproof/report"
require "stringio"

class TestReport < Minitest::Test
  def base_report(**overrides)
    Branchproof::Report.new(inventory: { decisions: [{ conditions: [{ index: 0 }, { index: 1 }] }] },
                            evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: true } },
                            analysis: { proven_count: 1, completeness: { observation: true, attribution: true, analysis: true } },
                            minima: [], baseline: { status: "PASSED", executed_tests: 1 }, diagnostics: [], **overrides)
  end

  def test_json_has_versioned_schema_and_truthful_zero_denominator
    output = StringIO.new
    base_report(inventory: { decisions: [] }).write(io: output, format: :json)
    document = JSON.parse(output.string)
    assert_equal "1.0", document.fetch("schema_version")
    assert_nil document.fetch("metrics").fetch("percentage")
  end

  def test_failed_baseline_returns_test_failure_exit
    report = base_report(baseline: { status: "FAILED" })
    assert_equal 1, report.exit_code
  end

  def test_incomplete_baseline_returns_runner_exit
    report = base_report(baseline: { status: "INCOMPLETE" })
    assert_equal 2, report.exit_code
  end

  def test_supported_denominator_excludes_unsupported_scope_and_counts_unexecuted
    inventory = { decisions: [
      { id: "supported", conditions: [{ index: 0 }, { index: 1 }] },
      { id: "unsupported", support_status: "UNSUPPORTED", conditions: [{ index: 0 }, { index: 1 }, { index: 2 }] },
      { id: "unexecuted", conditions: [{ index: 0 }] }
    ] }
    report = base_report(inventory: inventory,
                         evidence: { vectors: [{ decision_id: "supported", count: 1 }],
                                     completeness: { observation: true, attribution: true,
                                                     analysis: true } })
    output = StringIO.new
    report.write(io: output, format: :json)
    metrics = JSON.parse(output.string).fetch("metrics")
    assert_equal 3, metrics.fetch("discovered")
    assert_equal 2, metrics.fetch("supported")
    assert_equal 1, metrics.fetch("unsupported")
    assert_equal 3, metrics.fetch("eligible_conditions")
    assert_equal 1, metrics.fetch("unexecuted")
  end

  def test_empty_supported_scope_is_na_and_not_successful
    report = base_report(inventory: { decisions: [] }, baseline: { status: "PASSED", finalized: true })
    output = StringIO.new
    report.write(io: output, format: :json)
    assert_nil JSON.parse(output.string).dig("metrics", "percentage")
    assert_equal 2, report.exit_code
  end

  def test_level_one_allows_complete_observation_without_analysis
    report = base_report(level: 1, analysis: nil, baseline: { status: "PASSED", finalized: true },
                         evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: false } })
    assert_equal 0, report.exit_code
    output = StringIO.new
    report.write(io: output, format: :json)
    assert_nil JSON.parse(output.string).fetch("analysis")
  end

  def test_incomplete_observation_is_partial_lower_bound_and_exit_two
    report = base_report(baseline: { status: "PASSED", finalized: true },
                         evidence: { vectors: [{ decision_id: "x", values: [true], count: 1 }],
                                     completeness: { observation: false, attribution: true,
                                                     analysis: true } })
    output = StringIO.new
    report.write(io: output, format: :terminal)
    assert_includes output.string, "lower-bound"
    assert_equal 2, report.exit_code
  end

  def test_incomplete_analysis_is_partial_for_levels_two_and_three
    report = base_report(level: 2, baseline: { status: "PASSED", finalized: true },
                         evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: true } },
                         analysis: { proven_count: 0, completeness: { observation: true, attribution: true, analysis: false } })
    output = StringIO.new

    report.write(io: output, format: :terminal)

    assert_includes output.string, "lower-bound"
    assert_equal 2, report.exit_code
  end

  def test_terminal_renders_sources_vectors_masks_witnesses_and_minimum
    inventory = { source_units: [{ source_id: "s1", relative_path: "lib/example.rb" }],
                  decisions: [{ id: "d1", source_id: "s1", line: 4, expression: "a && b",
                                conditions: [{ id: "c1", index: 0, expression: "a" }, { id: "c2", index: 1, expression: "b" }] }] }
    evidence = {
      vectors: [{ id: "v1", decision_id: "d1", values: [true, nil], outcome: true, test_ids: ["test_one"],
                  count: 1 }], completeness: { observation: true, attribution: true, analysis: true }
    }
    analysis = {
      decisions: [{ decision_id: "d1", effective_masks_by_vector: { "v1" => 1 },
                    condition_results: [{ condition_id: "c1", status: "PROVEN", canonical_pair: %w[v1 v2] }, { condition_id: "c2", status: "NOT_PROVEN", constraint_result: { constraints: ["b=true"] } }] }], completeness: { observation: true, attribution: true, analysis: true }
    }
    output = StringIO.new
    Branchproof::Report.new(inventory: inventory, evidence: evidence, analysis: analysis,
                            minima: [{ objective: "tests", scope_decision_ids: ["d1"], status: "EXACT_MINIMUM", selected_ids: ["test_one"] }],
                            baseline: { status: "PASSED", finalized: true }, diagnostics: []).write(io: output, format: :terminal)
    %w[lib/example.rb v1 T - test_one PROVEN NOT_PROVEN b=true EXACT_MINIMUM Additional].each do |text|
      assert_includes output.string, text
    end
  end

  def test_terminal_uses_readable_names_fallbacks_and_collision_safe_ids
    decision_id = "12345678decision-full-id"
    vector_id = "12345678vector-full-id"
    evidence = {
      tests: [{ id: "test-a", class_name: "WidgetTest", method_name: "test_ready", source_path: "test/widget_test.rb", line: 12 }],
      vectors: [{ id: vector_id, decision_id: decision_id, values: [true], outcome: true,
                  test_ids: %w[test-a unknown-test], count: 1 }],
      completeness: { observation: true, attribution: true, analysis: true }
    }
    inventory = {
      source_units: [{ source_id: "source", relative_path: "lib/widget.rb" }],
      decisions: [{ id: decision_id, source_id: "source", line: 9,
                    expression: "ready?",
                    conditions: [{ id: "condition", index: 0, expression: "ready?" }] }]
    }
    analysis = { proven_count: 1, completeness: { observation: true, attribution: true, analysis: true },
                 decisions: [{ decision_id: decision_id,
                               condition_results: [{ condition_id: "condition", status: "PROVEN", canonical_pair: [vector_id, vector_id] }] }] }
    minimum = { objective: "tests", scope_decision_ids: [decision_id], selected_ids: ["unknown-test"], status: "EXACT_MINIMUM" }
    output = StringIO.new
    Branchproof::Report.new(inventory: inventory, evidence: evidence, analysis: analysis, minima: [minimum],
                            baseline: { status: "PASSED", executed_tests: 1, tests: [{ id: "unknown-test", name: "unknown-test" }] },
                            diagnostics: []).write(io: output, format: :terminal)

    assert_includes output.string, "Decision 12345678d"
    assert_includes output.string, "Vector 12345678v"
    assert_includes output.string, "WidgetTest#test_ready"
    assert_includes output.string, "unknown-"
    assert_includes output.string, "witness 12345678v + 12345678v"
    assert_includes output.string, "decisions: [12345678d]"
    refute_includes output.string, "effective_masks_by_vector"
  end

  def test_terminal_does_not_claim_zero_percent_when_analysis_is_unavailable
    report = base_report(level: 1, analysis: nil,
                         evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: false } })
    output = StringIO.new
    report.write(io: output, format: :terminal)

    assert_includes output.string, "MC/DC: not calculated"
    assert_includes output.string, "Analysis: NOT CALCULATED"
    assert_includes output.string, "NOT CALCULATED"
    refute_includes output.string, "0.0%"
  end

  def test_terminal_disambiguates_duplicate_names_and_uses_baseline_and_unknown_fallbacks
    inventory = { source_units: [{ source_id: "source", relative_path: "lib/example.rb" }],
                  decisions: [{ id: "decision", source_id: "source", line: 4, expression: "flag",
                                conditions: [{ id: "condition", index: 0, expression: "flag" }] }] }
    evidence = { tests: [
      { id: "first", class_name: "ExampleTest", method_name: "test_same", source: { path: "spec/example_test.rb", line: 10 } },
      { id: "second", class_name: "ExampleTest", method_name: "test_same", source: { path: "spec/example_test.rb", line: 11 } },
      { id: "third", class_name: "ExampleTest", method_name: "test_same", source: { path: "spec/example_test.rb", line: 11 } }
    ], vectors: [
      { id: "vector-one", decision_id: "decision", values: [true], outcome: true,
        test_ids: %w[first second third baseline unknown], count: 1 }
    ], completeness: { observation: true, attribution: true, analysis: true } }
    analysis = { proven_count: 1, completeness: { observation: true, attribution: true, analysis: true },
                 decisions: [{ decision_id: "decision", condition_results: [{ condition_id: "condition", status: "PROVEN" }] }] }
    report = Branchproof::Report.new(inventory: inventory, evidence: evidence, analysis: analysis, minima: [],
                                     baseline: { status: "PASSED", executed_tests: 1,
                                                 tests: [{ id: "baseline", name: "BaselineTest#test_old" }] }, diagnostics: [])
    output = StringIO.new
    report.write(io: output, format: :terminal)

    assert_includes output.string, "ExampleTest#test_same (spec/example_test.rb:10)"
    assert_includes output.string, "ExampleTest#test_same (spec/example_test.rb:11, third)"
    assert_includes output.string, "BaselineTest#test_old"
    assert_includes output.string, "unknown"
  end

  def test_terminal_short_ids_handle_an_eight_character_prefix_collision
    inventory = { decisions: [{ id: "12345678", conditions: [] }, { id: "12345678abcdef", conditions: [] }] }
    report = base_report(inventory: inventory, evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: true } })
    output = StringIO.new
    report.write(io: output, format: :terminal)

    assert_includes output.string, "Decision 12345678"
    assert_includes output.string, "Decision 12345678a"
  end

  def test_terminal_deduplication_and_level_specific_detail_do_not_change_json
    data = {
      "inventory" => { "decisions" => [{ "id" => "decision", "conditions" => [{ "id" => "condition", "index" => 0, "expression" => "flag" }] }] },
      "evidence" => {
        "vectors" => [{ "id" => "vector", "decision_id" => "decision", "values" => [true], "outcome" => true, "test_ids" => ["test"] }],
        "completeness" => { "observation" => true, "attribution" => true, "analysis" => true }
      },
      "analysis" => { "proven_count" => 1, "completeness" => { "observation" => true, "attribution" => true, "analysis" => true },
                      "decisions" => [{ "decision_id" => "decision", "condition_results" => [{ "condition_id" => "condition", "status" => "PROVEN", "canonical_pair" => %w[vector vector] }] }] },
      "minima" => [{ "objective" => "tests", "scope_decision_ids" => ["decision"], "selected_ids" => ["test"], "status" => "EXACT_MINIMUM" }]
    }
    report = Branchproof::Report.new(inventory: data["inventory"], evidence: data["evidence"], analysis: data["analysis"],
                                     minima: data["minima"] * 2, baseline: { "status" => "PASSED", "executed_tests" => 1 },
                                     diagnostics: [], level: 2)
    before = StringIO.new
    report.write(io: before, format: :json)
    terminal = StringIO.new
    report.write(io: terminal, format: :terminal)
    after = StringIO.new
    report.write(io: after, format: :json)

    assert_equal before.string, after.string
    assert_equal 1, terminal.string.scan("Tests (").length
    refute_includes terminal.string, "witness"
  end

  def test_level_one_conditions_are_not_calculated
    report = base_report(level: 1, analysis: nil,
                         evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: false } })
    output = StringIO.new
    report.write(io: output, format: :terminal)

    assert_equal 3, output.string.scan("NOT CALCULATED").length
    refute_includes output.string, "witness"
  end

  def test_terminal_preserves_infeasible_constraint_status_without_constraints
    inventory = { decisions: [{ id: "decision", conditions: [{ id: "condition", index: 0, expression: "flag" }] }] }
    constraint_result = { constraints: [], status: "INFEASIBLE_IN_MODEL",
                          feasibility_statement: "no counterpart satisfies the model" }
    condition_result = { condition_id: "condition", status: "NOT_PROVEN", constraint_result: constraint_result }
    analysis = {
      proven_count: 0,
      completeness: { observation: true, attribution: true, analysis: true },
      decisions: [{ decision_id: "decision", condition_results: [condition_result] }]
    }
    report = Branchproof::Report.new(inventory: inventory,
                                     evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: true } },
                                     analysis: analysis, minima: [], baseline: { status: "PASSED" }, diagnostics: [])
    output = StringIO.new
    report.write(io: output, format: :terminal)

    assert_includes output.string, "missing counterpart: INFEASIBLE_IN_MODEL; no counterpart satisfies the model"
    refute_includes output.string, "missing counterpart: )"
  end

  def test_terminal_keeps_exact_predicates_on_separate_readable_lines
    expression = "account.active?(user.id) && count >= 2"
    inventory = { decisions: [{ id: "decision", line: 17, expression: expression,
                                conditions: [{ id: "condition-one", index: 0, expression: "account.active?(user.id)" },
                                             { id: "condition-two", index: 1, expression: "count >= 2" }] }] }
    condition_results = [{ condition_id: "condition-one", status: "PROVEN" },
                         { condition_id: "condition-two", status: "NOT_PROVEN" }]
    analysis = { proven_count: 1, completeness: { observation: true, attribution: true, analysis: true },
                 decisions: [{ decision_id: "decision", condition_results: condition_results }] }
    report = Branchproof::Report.new(inventory: inventory,
                                     evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: true } },
                                     analysis: analysis, minima: [], baseline: { status: "PASSED" }, diagnostics: [])
    output = StringIO.new
    report.write(io: output, format: :terminal)

    assert_includes output.string, "Decision decision :17"
    assert_includes output.string, "  Decision: #{expression}"
    assert_includes output.string, "  Condition 0: account.active?(user.id)\n    PROVEN"
    assert_includes output.string, "  Condition 1: count >= 2\n    NOT_PROVEN"
  end

  def test_json_omits_source_bytes_and_preserves_false_values
    output = StringIO.new
    base_report(inventory: { source_units: [{ source_id: "s", original_bytes: "secret", relative_path: "x.rb" }] },
                analysis: nil, evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: false } },
                baseline: { status: "PASSED", finalized: true }).write(io: output, format: :json)
    document = JSON.parse(output.string)
    refute_includes output.string, "secret"
    return unless document.fetch("completeness").key?("analysis")

    assert_equal false,
                 document.fetch("completeness").fetch("analysis")
  end
end
