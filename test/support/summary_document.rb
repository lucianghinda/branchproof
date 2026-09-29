# frozen_string_literal: true

# Saved-report document with one decision per ranking case:
#   lib/a.rb:2  left && right  executed, 1/3 rules missing, 1/2 conditions unproven
#   lib/a.rb:9  x && y         executed, fully covered
#   lib/b.rb:5  p && q         unexecuted, 3/3 rules missing, 2/2 conditions unproven
#   lib/b.rb:12 legacy         unsupported
#   lib/c.rb:3  case kind      executed, 1/2 alternatives missing
module SummaryDocument
  def summary_document(status: "PASSED", analysis: true)
    document = {
      source_inventory: {
        source_units: %w[a b c].map { |name| { source_id: name, relative_path: "lib/#{name}.rb" } },
        decisions: [
          boolean_decision("partial", "a", 2, "left", "right"),
          boolean_decision("covered", "a", 9, "x", "y"),
          boolean_decision("unexecuted", "b", 5, "p", "q"),
          { id: "unsupported", source_id: "b", expression: "legacy", line: 12, support_status: "UNSUPPORTED",
            conditions: [] },
          { id: "multiway", source_id: "c", expression: "case kind", line: 3, column: 4, kind: "multiway",
            conditions: [], alternatives: [{ id: "alt_int", index: 0, expression: "Integer", line: 4 },
                                           { id: "alt_str", index: 1, expression: "String", line: 5 }] }
        ]
      },
      observations: {
        tests: [
          { id: "t_both", class_name: "ATest", method_name: "test_both", status: "passed",
            source: { relative_path: "test/a_test.rb", line: 10 } },
          { id: "t_left", class_name: "ATest", method_name: "test_left_false", status: "passed",
            source: { relative_path: "test/a_test.rb", line: 20 } },
          { id: "t_kind", class_name: "CTest", method_name: "test_kind", status: "passed",
            source: { relative_path: "test/c_test.rb", line: 4 } }
        ],
        vectors: [
          { id: "v1", decision_id: "partial", values: [true, true], outcome: true, test_ids: ["t_both"] },
          { id: "v2", decision_id: "partial", values: [false, nil], outcome: false, test_ids: ["t_left"] },
          { id: "v3", decision_id: "covered", values: [true, true], outcome: true, test_ids: ["t_both"] },
          { id: "v4", decision_id: "covered", values: [true, false], outcome: false, test_ids: ["t_both"] },
          { id: "v5", decision_id: "covered", values: [false, nil], outcome: false, test_ids: ["t_both"] },
          { id: "v6", decision_id: "multiway", values: [true, nil], outcome: true, test_ids: ["t_kind"] }
        ]
      },
      baseline: { status: status, finalized: true },
      completeness: { observation: true, attribution: true, analysis: true }
    }
    document[:analysis] = summary_analysis if analysis
    document
  end

  private

  def boolean_decision(id, source, line, left, right)
    { id: id, source_id: source, expression: "#{left} && #{right}", line: line, column: 4,
      conditions: [{ id: "#{id}_0", index: 0, expression: left, line: line },
                   { id: "#{id}_1", index: 1, expression: right, line: line }] }
  end

  def summary_analysis
    {
      decisions: [
        boolean_analysis("partial", proven: [true, false], covered: [true, false, true]),
        boolean_analysis("covered", proven: [true, true], covered: [true, true, true]),
        boolean_analysis("unexecuted", proven: [false, false], covered: [false, false, false]),
        { decision_id: "multiway", kind: "multiway", condition_results: [],
          coverage: { alternative: { missing_alternatives: ["alt_str"], alternatives: [] } } }
      ],
      coverage: { mcdc: { proven_conditions: 3, supported_conditions: 6, percentage: 50.0 },
                  decision_table: { covered_rules: 5, required_rules: 9, percentage: 55.56 } }
    }
  end

  def boolean_analysis(id, proven:, covered:)
    rules = [[%w[true true], true], [%w[true false], false], [%w[false dont_care], false]]
    { decision_id: id,
      condition_results: proven.each_with_index.map do |value, index|
        { condition_id: "#{id}_#{index}", status: value ? "PROVEN" : "NOT_PROVEN" }
      end,
      decision_table: { status: "calculated", required_rules: 3, covered_rules: covered.count(true),
                        missing_rules: covered.count(false),
                        rules: rules.each_with_index.map do |(conditions, outcome), index|
                          { label: "R#{index + 1}", conditions: conditions, outcome: outcome,
                            coverage: covered[index] ? "covered" : "missing" }
                        end } }
  end
end
