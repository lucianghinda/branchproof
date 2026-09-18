# frozen_string_literal: true

require "test_helper"
require_relative "support/ruby_constructs"

class TestRubyConstructAnalysis < Minitest::Test
  DECISION_STATUSES = %w[covered partial unexecuted unsupported].freeze
  TABLE_STATUSES = %w[calculated not_calculated].freeze

  def decision_rows(document)
    document.fetch(:analysis).fetch(:decisions).to_h { |row| [row.fetch(:decision_id), row] }
  end

  def supported?(decision)
    decision.fetch(:support_status, "SUPPORTED").to_s.casecmp("SUPPORTED").zero?
  end

  def test_every_native_fixture_has_an_analysis_with_correct_population_denominators
    assert_equal 144, RubyConstructs.entries.length
    assert_equal 144, RubyConstructs.entries.map { |entry| entry.fetch("id") }.uniq.length

    RubyConstructs.entries.each do |entry|
      id = entry.fetch("id")
      inventory = RubyConstructs.inventory(id)
      document = RubyConstructs.document(id)
      rows = decision_rows(document)
      decisions = inventory.fetch(:decisions)
      selected_cases = entry.fetch("cases")
      expected_owners = selected_cases.map { |sample| "RubyConstructs##{id}/#{sample.fetch("name")}" }
      observed_owner_ids = document.fetch(:evidence).fetch(:vectors).flat_map { |vector| vector.fetch(:test_ids) }
      assert observed_owner_ids.all? { |owner| expected_owners.include?(owner) }, "#{id}: unresolvable evidence owner"

      assert_equal decisions.map { |decision| decision.fetch(:id) }.sort, rows.keys.sort, id
      decisions.each do |decision|
        row = rows.fetch(decision.fetch(:id), id)
        if supported?(decision)
          if decision.fetch(:kind, "boolean").to_s == "boolean"
            coverage = row.fetch(:coverage)
            %i[decision condition condition_decision mcdc].each do |criterion|
              assert_includes DECISION_STATUSES, coverage.dig(criterion, :status), "#{id} #{criterion}"
            end
            assert_equal decision.fetch(:conditions).length, coverage.dig(:condition, :condition_count), id
            assert_operator coverage.dig(:condition, :covered_values), :<=, coverage.dig(:condition, :required_values)
            assert_operator coverage.dig(:mcdc, :proven_conditions), :<=, coverage.dig(:mcdc, :condition_count)
            assert_operator coverage.dig(:decision, :covered_outcomes), :<=, coverage.dig(:decision, :required_outcomes)
          else
            alternative = row.dig(:coverage, :alternative)
            refute_nil alternative, id
            assert_equal decision.fetch(:alternatives).length, alternative.fetch(:required_alternatives), id
            assert_operator alternative.fetch(:covered_alternatives), :<=, alternative.fetch(:required_alternatives)
            assert_equal "not_applicable", row.dig(:coverage, :mcdc, :status), id
          end
        else
          assert_equal "unsupported", row.dig(:coverage, decision.fetch(:kind, "boolean").to_s == "boolean" ? :decision : :alternative, :status), id
        end
      end

      aggregate = document.fetch(:analysis).fetch(:coverage)
      boolean_supported = decisions.count { |decision| supported?(decision) && decision.fetch(:kind, "boolean") == "boolean" }
      condition_count = decisions.select { |decision| supported?(decision) && decision.fetch(:kind, "boolean") == "boolean" }
                                 .sum { |decision| decision.fetch(:conditions).length }
      assert_equal boolean_supported, aggregate.dig(:decision, :supported_decisions), id
      assert_equal boolean_supported, aggregate.dig(:condition_decision, :supported_decisions), id
      assert_equal condition_count, aggregate.dig(:mcdc, :supported_conditions), id
      assert_equal condition_count * 2, aggregate.dig(:condition, :required_values), id
      assert_operator aggregate.dig(:condition, :covered_values), :<=, aggregate.dig(:condition, :required_values)
      boolean_decisions = decisions.select { |decision| decision.fetch(:kind, "boolean") == "boolean" }
      boolean_decisions.each do |decision|
        table = rows.fetch(decision.fetch(:id)).fetch(:decision_table)
        if supported?(decision)
          assert_equal "calculated", table.fetch(:status), "#{id}: supported Boolean table"
          assert_equal table.fetch(:generated_rules) - table.fetch(:impossible_rules), table.fetch(:required_rules), id
          assert_equal decision.fetch(:conditions).length, table.fetch(:rules).first.fetch(:conditions).length
        else
          assert_equal "not_calculated", table.fetch(:status), id
          assert_equal "unsupported_decision", table.fetch(:reason), id
        end
      end
      expected_analyzed = boolean_decisions.count { |decision| supported?(decision) }
      assert_equal expected_analyzed, aggregate.dig(:decision_table, :decisions_analyzed), id
      expected_not_calculated = boolean_decisions.count { |decision| !supported?(decision) }
      assert_equal expected_not_calculated, aggregate.dig(:decision_table, :not_calculated_decisions), id
    end
  end

  def test_partial_and_empty_populations_keep_unexecuted_status_and_do_not_assume_completeness
    id = "LOG-01"
    decision = RubyConstructs.inventory(id).fetch(:decisions).find { |item| item.fetch(:kind) == "boolean" }
    empty = RubyConstructs.document(id, cases: [])
    empty_row = decision_rows(empty).fetch(decision.fetch(:id))
    %i[decision condition condition_decision mcdc].each do |criterion|
      assert_equal "unexecuted", empty_row.dig(:coverage, criterion, :status)
    end
    assert_equal 0, empty.fetch(:evidence).fetch(:vectors).length

    partial = RubyConstructs.document(id, cases: [RubyConstructs.entry(id).fetch("cases").first])
    partial_row = decision_rows(partial).fetch(decision.fetch(:id))
    assert_equal([[[false, nil], false]], partial.fetch(:evidence).fetch(:vectors).map { |vector| [vector[:values], vector[:outcome]] })
    assert_equal "partial", partial_row.dig(:coverage, :decision, :status)
    assert_equal(%w[NOT_PROVEN NOT_PROVEN], partial_row.fetch(:condition_results).map { |result| result.fetch(:status) })
    assert_equal(%w[missing_effective_sign missing_effective_sign],
                 partial_row.fetch(:condition_results).map { |result| result.fetch(:reason) })
    assert_equal [0, 2], [partial_row.dig(:coverage, :mcdc, :proven_conditions), partial_row.dig(:coverage, :mcdc, :condition_count)]
  end

  def test_evidence_owners_and_aborted_executions_are_preserved_without_coverage_credit
    id = "LOG-01"
    inventory = RubyConstructs.inventory(id)
    decision = inventory.fetch(:decisions).find { |item| item.fetch(:kind) == "boolean" }
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default, run_id: "aborted")
    owner = "RubyConstructs##{id}/aborted/0"
    evidence.register_test(test: { id: owner, name: owner, adapter: "ruby_constructs" })
    result = evidence.record(execution: { run_id: "aborted", decision_id: decision.fetch(:id), test_id: owner,
                                          phase: "body", observations: [], outcome: nil, status: "aborted" })
    assert_equal "recorded", result.fetch(:status)
    snapshot = evidence.snapshot
    assert_equal 1, snapshot.fetch(:abort_counts).fetch(decision.fetch(:id))
    assert_empty snapshot.fetch(:vectors)
    analysis = Branchproof::Analyzer.new(inventory: inventory, evidence: snapshot,
                                         limits: Branchproof::Limits.default).call
    row = analysis.fetch(:decisions).find { |item| item.fetch(:decision_id) == decision.fetch(:id) }
    assert_equal "unexecuted", row.dig(:coverage, :decision, :status)
    assert_empty(row.dig(:coverage, :decision, :outcomes).flat_map { |bucket| bucket.fetch(:vector_ids) })
  end

  def test_real_pattern_mismatch_abort_is_counted_without_becoming_an_observation
    document = RubyConstructs.document("PAT-02")
    decision = document.fetch(:inventory).fetch(:decisions).first
    evidence = document.fetch(:evidence)
    assert_equal 1, evidence.fetch(:abort_counts).fetch(decision.fetch(:id).to_sym)
    assert_equal([[[true], true]], evidence.fetch(:vectors).map { |vector| [vector.fetch(:values), vector.fetch(:outcome)] })
    row = document.fetch(:analysis).fetch(:decisions).first
    alternative = row.dig(:coverage, :alternative, :alternatives).first
    assert_equal true, alternative.dig(:selected, :observed)
    assert_equal false, alternative.dig(:not_selected, :observed)
  end

  def test_decision_table_is_consistent_and_reachability_switch_only_changes_reachability
    %w[LOG-01 LOG-02 LOG-08 PAT-24].each do |id|
      inventory = RubyConstructs.inventory(id)
      decision = inventory.fetch(:decisions).find { |item| item.fetch(:kind, "boolean") == "boolean" && item.fetch(:conditions).length > 1 }
      next unless decision

      with_reachability = RubyConstructs.document(id, reachability: true)
      without_reachability = RubyConstructs.document(id, reachability: false)
      table = decision_rows(with_reachability).fetch(decision.fetch(:id)).fetch(:decision_table)
      table_without = decision_rows(without_reachability).fetch(decision.fetch(:id)).fetch(:decision_table)
      assert_includes TABLE_STATUSES, table.fetch(:status), id
      next unless table.fetch(:status) == "calculated"

      assert_equal table.fetch(:rules).map { |rule| rule.fetch(:id) }, table.fetch(:rules).map { |rule| rule.fetch(:id) }.uniq
      table.fetch(:rules).each do |rule|
        assert_equal decision.fetch(:conditions).length, rule.fetch(:conditions).length
        assert(rule.fetch(:conditions).all? { |value| Branchproof::DecisionTable::CONDITION_VALUES.include?(value) })
        assert_includes Branchproof::DecisionTable::REACHABILITY_STATUSES, rule.fetch(:reachability)
      end
      assert(table_without.fetch(:rules).none? { |rule| rule.fetch(:reachability) == "statically_impossible" })
      assert_equal(table.fetch(:rules).map { |rule| [rule.fetch(:conditions), rule.fetch(:outcome)] },
                   table_without.fetch(:rules).map { |rule| [rule.fetch(:conditions), rule.fetch(:outcome)] })
    end
  end

  def test_explicit_native_logic_anchors_preserve_short_circuit_and_negation_shapes
    expected = {
      "LOG-01" => [%w[false dont_care], %w[true false], %w[true true]],
      "LOG-02" => [%w[true dont_care], %w[false true], %w[false false]],
      "LOG-05" => [%w[false], %w[true]]
    }
    expected.each do |id, shapes|
      decision = RubyConstructs.inventory(id).fetch(:decisions).find { |item| item.fetch(:kind) == "boolean" }
      table = RubyConstructs.document(id).fetch(:analysis).fetch(:decisions).find { |item| item.fetch(:decision_id) == decision.fetch(:id) }
                            .fetch(:decision_table)
      assert_equal shapes, table.fetch(:rules).map { |rule| rule.fetch(:conditions) }, id
    end
  end

  def test_independent_vector_anchors_cover_nested_negated_loop_pattern_and_implicit_constructs
    anchors = {
      "LOG-08" => [[[false, nil, nil], false], [[true, true, nil], true], [[true, false, true], true], [[true, false, false], false]],
      "LOOP-01" => [[[false], false], [[true], true]],
      "PAT-24" => [[[true, true], true], [[true, false], false], [[false, nil], false]],
      "NIL-01" => [[[true, false], true], [[false, true], true]],
      "ASGN-01" => [[[true, false], true], [[false, true], true]]
    }
    anchors.each do |id, expected|
      vectors = RubyConstructs.document(id).fetch(:evidence).fetch(:vectors)
      if id == "PAT-24"
        guard = RubyConstructs.inventory(id).fetch(:decisions).find { |decision| decision[:context] == "pattern_guard" }
        vectors = vectors.select { |vector| vector[:decision_id] == guard.fetch(:id) }
      end
      actual = vectors.map { |vector| [vector.fetch(:values), vector.fetch(:outcome)] }
      assert_equal expected.sort_by(&:to_s), actual.sort_by(&:to_s), id
    end
    log08 = RubyConstructs.document("LOG-08").fetch(:analysis).fetch(:decisions).first
    assert_equal [3, 3], [log08.dig(:coverage, :mcdc, :proven_conditions), log08.dig(:coverage, :mcdc, :condition_count)]
    assert_equal [2, 2], [RubyConstructs.document("NIL-01").fetch(:analysis).fetch(:coverage).dig(:alternative, :covered_alternatives),
                          RubyConstructs.document("NIL-01").fetch(:analysis).fetch(:coverage).dig(:alternative, :required_alternatives)]

    log01 = RubyConstructs.document("LOG-01")
    row = log01.fetch(:analysis).fetch(:decisions).first
    assert_equal [2, 2], [row.dig(:coverage, :mcdc, :proven_conditions), row.dig(:coverage, :mcdc, :condition_count)]
    vectors = log01.fetch(:evidence).fetch(:vectors).to_h { |vector| [vector.fetch(:id), vector] }
    row.fetch(:condition_results).each_with_index do |condition, index|
      left, right = condition.fetch(:canonical_pair).map { |id| vectors.fetch(id) }
      refute_nil left.fetch(:values)[index]
      refute_nil right.fetch(:values)[index]
      refute_equal left.fetch(:values)[index], right.fetch(:values)[index]
      assert_equal true, left.fetch(:outcome) != right.fetch(:outcome)
    end
  end
end
