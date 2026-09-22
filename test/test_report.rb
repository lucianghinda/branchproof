# frozen_string_literal: true

require "test_helper"
require "branchproof/report"
require "branchproof/analyzer"
require "stringio"

class TestReport < Minitest::Test
  def test_offline_json_preserves_the_saved_document_and_completeness
    io = StringIO.new
    base_report.write(io: io, format: :json)
    document = JSON.parse(io.string)
    document["runtime"] = "original Ruby runtime"
    document["run_metadata"] = { "project_root" => "/old/root", "requested_level" => 3 }
    document["completeness"]["observation"] = false
    report = Branchproof::Report.from_document(document: document, level: 1)
    output = StringIO.new
    report.write(io: output, format: :json)
    assert_equal document, JSON.parse(output.string)
    assert_equal 2, report.exit_code
  end

  def test_diagnostics_identify_sources_in_every_live_and_saved_view
    diagnostics = [
      { code: "not_instrumented", message: "no supported conditions to instrument", source_id: "one" },
      { code: "unsupported_source", message: "unsupported source syntax: unsupported_flip_flop", source_id: "two" },
      { code: "loader_conflict", message: "another hook is installed" }
    ]
    report = base_report(inventory: { decisions: [], source_units: [
                           { source_id: "one", relative_path: "app/one.rb" },
                           { source_id: "two", relative_path: "app/two.rb" }
                         ] }, diagnostics: diagnostics)
    json = StringIO.new
    report.write(io: json, format: :json)
    document = JSON.parse(json.string)
    assert_equal diagnostics.map { |item| item.transform_keys(&:to_s) }, document["diagnostics"]
    [report, *%i[decisions conditions tests].map do |view|
      Branchproof::Report.from_document(document: document, view: view)
    end].each do |renderer|
      output = StringIO.new
      renderer.write(io: output, format: :terminal)
      assert_includes output.string, "Skipped app/one.rb: no supported conditions to instrument"
      assert_includes output.string, "Skipped app/two.rb: unsupported source syntax: unsupported_flip_flop"
      assert_includes output.string, "another hook is installed"
    end
  end

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
    assert_equal "1.4", document.fetch("schema_version")
    assert_nil document.fetch("metrics").fetch("percentage")
  end

  def test_report_persists_separate_policy_and_uses_policy_exit_status
    report = base_report(inventory: { decisions: [{ id: "d", conditions: [{ id: "c", index: 0 }] }] },
                         evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: true } },
                         analysis: { coverage: { mcdc: { proven_conditions: 0, supported_conditions: 1 } },
                                     completeness: { observation: true, attribution: true, analysis: true } },
                         baseline: { status: "PASSED", finalized: true }, minimum: { mcdc: 100 })
    output = StringIO.new
    report.write(io: output, format: :json)
    document = JSON.parse(output.string)

    assert_equal "1.4", document.fetch("schema_version")
    assert_equal "failed", document.dig("coverage_policy", "status")
    assert_equal 0, document.dig("coverage_policy", "gates", 0, "numerator")
    assert_equal 1, document.dig("coverage_policy", "gates", 0, "denominator")
    assert_equal 1, report.exit_code
  end

  def test_saved_report_policy_override_preserves_input_schema_and_top_level_completeness
    document = JSON.parse(base_report(
      inventory: { decisions: [{ id: "d", conditions: [{ id: "c", index: 0 }] }] },
      evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: true } },
      analysis: { coverage: { mcdc: { proven_conditions: 1, supported_conditions: 1 } },
                  completeness: { observation: true, attribution: true, analysis: true } },
      baseline: { status: "PASSED", finalized: true }
    ).then { |report| StringIO.new.tap { |io| report.write(io: io, format: :json) }.string })
    document["schema_version"] = "1.3"
    document.delete("coverage_policy")
    document["completeness"]["analysis"] = false

    report = Branchproof::Report.from_document(document: document, minimum: { mcdc: 100 })
    output = StringIO.new
    report.write(io: output, format: :json)
    overridden = JSON.parse(output.string)

    assert_equal "1.3", overridden.fetch("schema_version")
    assert_equal "unavailable", overridden.dig("coverage_policy", "status")
    assert_equal 2, report.exit_code
    assert_equal "1.3", document.fetch("schema_version")
    refute document.key?("coverage_policy")
  end

  def test_rspec_baseline_uses_example_counts_in_terminal_header
    report = base_report(run_metadata: { framework: "rspec" },
                         baseline: { status: "PASSED", executed_tests: 3,
                                     failed_tests: 1, skipped_tests: 2 })
    output = StringIO.new
    report.write(io: output, format: :terminal)

    assert_includes output.string, "Tests: PASSED (3 examples, 1 failed, 2 skipped)"
  end

  def test_failed_baseline_returns_test_failure_exit
    report = base_report(baseline: { status: "FAILED" })
    assert_equal 1, report.exit_code
  end

  def test_missing_filter_preserves_json_and_exit_status_after_terminal_rendering
    filtered = base_report(missing_only: true)
    full = base_report
    filtered.write(io: StringIO.new, format: :terminal)
    filtered_json = StringIO.new
    full_json = StringIO.new
    filtered.write(io: filtered_json, format: :json)
    full.write(io: full_json, format: :json)

    assert_equal JSON.parse(full_json.string), JSON.parse(filtered_json.string)
    assert_equal full.exit_code, filtered.exit_code
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

  def test_terminal_explains_missing_counterpart_without_raw_constraint_hashes
    inventory = { source_units: [{ source_id: "source", relative_path: "lib/example.rb" }],
                  decisions: [{ id: "decision", source_id: "source", line: 8, expression: "left && right",
                                conditions: [{ id: "left", index: 0, expression: "left" },
                                             { id: "right", index: 1, expression: 'command == "install"' }] }] }
    existing = { id: "observed", decision_id: "decision", values: [true, true], outcome: true,
                 test_ids: ["test-existing"], count: 1 }
    candidate = { id: "candidate-1-false", decision_id: "decision", values: [true, false], outcome: false }
    analysis = { proven_count: 0, completeness: { observation: true, attribution: true, analysis: true },
                 decisions: [{ decision_id: "decision", condition_results: [
                   { condition_id: "left", status: "NOT_PROVEN" },
                   { condition_id: "right", status: "NOT_PROVEN",
                     constraint_result: { constraints: [{ condition_index: 1, value: false }],
                                          candidate_vectors: [candidate], existing_vector_id: "observed",
                                          feasibility_statement: "Boolean requirement; application-level feasibility unknown" } }
                 ] }] }
    report = Branchproof::Report.new(
      inventory: inventory,
      evidence: { tests: [{ id: "test-existing", class_name: "ExampleTest", method_name: "test_existing" }],
                  vectors: [existing], completeness: { observation: true, attribution: true, analysis: true } },
      analysis: analysis, minima: [], baseline: { status: "PASSED" }, diagnostics: []
    )
    output = StringIO.new

    report.write(io: output, format: :terminal)

    assert_includes output.string, 'command == "install" is falsey'
    assert_includes output.string, "Need an observation where:\n        left is truthy\n        command == \"install\" is falsey"
    assert_includes output.string, "Expected decision: false [TF]"
    assert_includes output.string, "ExampleTest#test_existing"
    assert_includes output.string, "Boolean requirement; application-level feasibility unknown"
    refute_includes output.string, "condition_index"
    refute_includes output.string, "candidate_vectors"
  end

  def test_missing_only_renders_only_missing_conditions_and_context
    inventory = { decisions: [
      { id: "proven-decision", expression: "ready", conditions: [{ id: "proven", index: 0, expression: "ready" }] },
      { id: "missing-decision", expression: "left && right",
        conditions: [{ id: "missing", index: 0, expression: "left" }, { id: "proven-too", index: 1, expression: "right" }] }
    ] }
    analysis = { proven_count: 2, completeness: { observation: true, attribution: true, analysis: true },
                 decisions: [
                   { decision_id: "proven-decision", condition_results: [{ condition_id: "proven", status: "PROVEN" }] },
                   { decision_id: "missing-decision", condition_results: [
                     { condition_id: "missing", status: "NOT_PROVEN", constraint_result: { constraints: [] } },
                     { condition_id: "proven-too", status: "PROVEN" }
                   ] }
                 ] }
    report = Branchproof::Report.new(inventory: inventory, evidence: { vectors: [] }, analysis: analysis,
                                     minima: [{ objective: "tests", status: "EXACT_MINIMUM", selected_ids: ["test"] }],
                                     baseline: { status: "PASSED" }, diagnostics: [], missing_only: true)
    output = StringIO.new

    report.write(io: output, format: :terminal)

    assert_includes output.string, "Missing conditions: 1 across 1 decision"
    assert_includes output.string, "Decision missing-"
    assert_includes output.string, "Condition 0: left"
    refute_includes output.string, "Decision proven-decision"
    refute_includes output.string, "Condition 1: right"
    refute_includes output.string, "Supporting sets:"
  end

  def test_missing_case_lists_both_required_observations_when_no_effective_observation_exists
    decision = { id: "decision", expression: "left || right",
                 conditions: [{ id: "left", index: 0, expression: "left" },
                              { id: "right", index: 1, expression: "right" }] }
    candidates = [{ values: [false, true], outcome: true }, { values: [false, false], outcome: false }]
    result = { condition_id: "right", status: "NOT_PROVEN",
               constraint_result: { status: "CANDIDATE", candidate_vectors: candidates } }
    report = base_report(inventory: { decisions: [decision] }, missing_only: true,
                         analysis: { decisions: [{ decision_id: "decision", condition_results: [result] }] })
    output = StringIO.new
    report.write(io: output, format: :terminal)

    assert_includes output.string, "Expected decision: true [FT]"
    assert_includes output.string, "Expected decision: false [FF]"
    assert_includes output.string, "right is truthy"
    assert_includes output.string, "right is falsey"
  end

  def test_missing_only_distinguishes_unavailable_analysis_from_no_missing_conditions
    unavailable = base_report(level: 1, analysis: nil, missing_only: true,
                              evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: false } })
    unavailable_output = StringIO.new
    unavailable.write(io: unavailable_output, format: :terminal)
    assert_includes unavailable_output.string, "Cannot identify missing conditions"
    refute_includes unavailable_output.string, "No missing conditions"

    complete = base_report(inventory: { decisions: [{ id: "decision", conditions: [{ id: "condition", index: 0 }] }] },
                           missing_only: true,
                           analysis: { proven_count: 1,
                                       completeness: { observation: true, attribution: true, analysis: true },
                                       decisions: [{ decision_id: "decision",
                                                     condition_results: [{ condition_id: "condition", status: "PROVEN" }] }] })
    complete_output = StringIO.new
    complete.write(io: complete_output, format: :terminal)
    assert_includes complete_output.string, "No missing conditions"
  end

  def test_coverage_ladder_terminal_has_denominators_evidence_and_level_one_status
    tree = { type: :and, left: { type: :atom, index: 0 }, right: { type: :atom, index: 1 } }
    inventory = { source_units: [{ source_id: "s", relative_path: "lib/example.rb" }],
                  decisions: [{ id: "d", source_id: "s", line: 4, expression: "a && b", tree: tree,
                                conditions: [{ id: "a", index: 0, expression: "a" }, { id: "b", index: 1, expression: "b" }] }] }
    evidence = { tests: [{ id: "admin", name: "AdminTest#test_false" }], vectors: [
      { id: "v1", decision_id: "d", values: [false, nil], outcome: false, test_ids: ["admin"], count: 1 },
      { id: "v2", decision_id: "d", values: [true, true], outcome: true, test_ids: ["admin"], count: 1 }
    ], completeness: { observation: true, attribution: true, analysis: true } }
    analysis = Branchproof::Analyzer.new(inventory: inventory, evidence: evidence, limits: {}).call
    report = Branchproof::Report.new(inventory: inventory, evidence: evidence, analysis: analysis, minima: [],
                                     baseline: { status: "PASSED", finalized: true }, diagnostics: [], level: 1)
    output = StringIO.new
    report.write(io: output, format: :terminal)
    assert_includes output.string, "Decision coverage"
    assert_includes output.string, "truth values"
    assert_includes output.string, "Coverage: D=PASS"
    assert_includes output.string, "C=FAIL"
    assert_includes output.string, "1/2 conditions fully covered"
    refute_includes output.string, "Outcome true:"
    assert_equal 0, report.exit_code

    detailed = Branchproof::Report.new(inventory: inventory, evidence: evidence, analysis: analysis, minima: [],
                                       baseline: { status: "PASSED", finalized: true }, diagnostics: [], level: 3)
    detail_output = StringIO.new
    detailed.write(io: detail_output, format: :terminal)
    assert_includes detail_output.string, "C=FAIL (3/4 values; 1/2 conditions fully covered)"
    assert_includes detail_output.string, "C/D=FAIL"
    assert_includes detail_output.string, "MC/DC=FAIL (1/2 conditions)"
    assert_includes detail_output.string, "Outcome true: observed; tests: AdminTest#test_false"
    assert_includes detail_output.string, "Value false: missing; tests: none recorded"
    assert_includes detail_output.string, "Missing values for b: false"
    assert_includes detail_output.string, "b is falsey"
  end

  def test_level_one_honors_errors_in_available_analysis
    report = base_report(level: 1, baseline: { status: "PASSED", finalized: true },
                         analysis: { proven_count: 0,
                                     completeness: { observation: true, attribution: true, analysis: false } },
                         evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: true } })

    output = StringIO.new
    report.write(io: output, format: :terminal)

    assert_includes output.string, "Analysis: PARTIAL"
    assert_equal 2, report.exit_code
  end

  def test_all_levels_retain_the_same_live_analysis
    analysis = { proven_count: 1, coverage: { mcdc: { proven_conditions: 1, supported_conditions: 1, percentage: 100.0 } },
                 completeness: { observation: true, attribution: true, analysis: true } }
    documents = [1, 2, 3].map do |level|
      output = StringIO.new
      base_report(level: level, analysis: analysis).write(io: output, format: :json)
      JSON.parse(output.string)
    end

    actual = documents.map { |document| document.fetch("analysis") }
    assert_equal Array.new(3, JSON.parse(JSON.generate(analysis))), actual
  end
end
