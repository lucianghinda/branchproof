# frozen_string_literal: true

require "test_helper"

class TestEvidenceRepetition < Minitest::Test
  def setup
    @inventory = {
      decisions: [{ id: "d", kind: "implicit", context: "value", conditions: [], tree: nil,
                    alternatives: [{ index: 0, id: "d0" }, { index: 1, id: "d1" }] }],
      source_units: []
    }
    @limits = Branchproof::Limits.default
  end

  def execution(run_id: "run", test_id: "test", phase: "body", observations: [[0, true], [1, false]],
                outcome: true, status: "completed")
    { run_id: run_id, decision_id: "d", test_id: test_id, phase: phase,
      observations: observations, outcome: outcome, status: status }
  end

  def test_repeated_valid_execution_skips_vector_digest_but_preserves_counts_and_phase_attribution
    evidence = Branchproof::Evidence.new(inventory: @inventory, limits: @limits, run_id: "run")
    evidence.register_test(test: { id: "test", name: "test", adapter: "test" })
    calls = 0
    original = Branchproof::Records.method(:id)
    Branchproof::Records.stub(:id, lambda { |value|
      calls += 1
      original.call(value)
    }) do
      first = execution.merge(run_id: +"run", test_id: +"test", phase: +"body")
      assert_equal "recorded", evidence.record(execution: first).fetch(:status)
      first[:observations][0][1] = false
      first[:run_id] << "-caller-mutated"
      first[:test_id] << "-caller-mutated"
      first[:phase] << "-caller-mutated"
      second = execution
      assert_equal "recorded", evidence.record(execution: second).fetch(:status)
      second[:observations][0][1] = false
      assert_equal "rejected", evidence.record(execution: second).fetch(:status)
    end
    assert_equal 1, calls
    vector = evidence.snapshot.fetch(:vectors).fetch(0)
    assert_equal [[true, false]], [vector.fetch(:values)]
    assert_equal 2, vector.fetch(:count)
    assert_equal 2, evidence.snapshot.dig(:tests, 0, :phase_counts, "body")
    evidence.register_test(test: { id: "test", name: "replacement", phase_counts: {} })
    evidence.record(execution: execution)
    assert_equal 3, evidence.snapshot.dig(:tests, 0, :phase_counts, "body")
    assert_equal 1, evidence.instance_variable_get(:@repetition_cache).size
  end

  def test_reregistering_canonical_phase_counts_does_not_double_count_local_observations
    evidence = Branchproof::Evidence.new(inventory: @inventory, limits: @limits, run_id: "run")
    evidence.register_test(test: { id: "test", name: "test", adapter: "test" })
    evidence.record(execution: execution)

    evidence.register_test(test: { id: "test", name: "test", adapter: "test", phase_counts: { body: 1 } })

    assert_equal({ "body" => 1 }, evidence.snapshot.dig(:tests, 0, :phase_counts))
  end

  def test_cache_key_includes_phase_test_outcome_and_run_and_abort_is_not_cached
    evidence = Branchproof::Evidence.new(inventory: @inventory, limits: @limits, run_id: "run")
    %w[test other].each { |id| evidence.register_test(test: { id: id, name: id, adapter: "test" }) }
    assert_equal "recorded", evidence.record(execution: execution).fetch(:status)
    assert_equal "recorded", evidence.record(execution: execution(phase: "teardown")).fetch(:status)
    assert_equal "recorded", evidence.record(execution: execution(test_id: "other")).fetch(:status)
    assert_equal "recorded", evidence.record(execution: execution(status: "aborted", outcome: nil)).fetch(:status)
    assert_equal "rejected", evidence.record(execution: execution(run_id: "other")).fetch(:status)
    assert_equal "rejected", evidence.record(execution: execution(outcome: false)).fetch(:status)
    assert_equal 3, evidence.snapshot.fetch(:vectors).fetch(0).fetch(:count)
    assert_equal 1, evidence.snapshot.fetch(:abort_counts).fetch("d")
    assert_equal 1, evidence.snapshot.dig(:tests, 0, :phase_counts, "body")
  end

  def test_merge_clears_cache_before_local_repetition
    evidence = Branchproof::Evidence.new(inventory: @inventory, limits: @limits, run_id: "run")
    evidence.register_test(test: { id: "test", name: "test", adapter: "test" })
    evidence.record(execution: execution)
    incoming = Branchproof::Evidence.new(inventory: @inventory, limits: @limits, run_id: "other")
    incoming.register_test(test: { id: "other", name: "other", adapter: "test" })
    incoming.record(execution: execution(run_id: "other", test_id: "other"))
    assert_equal "merged", evidence.merge(snapshot: incoming.snapshot).fetch(:status)
    calls = 0
    original = Branchproof::Records.method(:id)
    Branchproof::Records.stub(:id, lambda { |value|
      calls += 1
      original.call(value)
    }) do
      evidence.record(execution: execution)
    end
    assert_operator calls, :>, 0
    assert_equal 3, evidence.snapshot.fetch(:vectors).fetch(0).fetch(:count)
  end

  def test_unattributed_repetition_updates_count_without_owner_association
    evidence = Branchproof::Evidence.new(inventory: @inventory, limits: @limits, run_id: "run")
    sample = execution(test_id: nil)
    assert_equal "recorded", evidence.record(execution: sample).fetch(:status)
    assert_equal "recorded", evidence.record(execution: sample).fetch(:status)
    vector = evidence.snapshot.fetch(:vectors).fetch(0)
    assert_equal 2, vector.fetch(:count)
    assert_equal 2, vector.fetch(:unattributed_count)
    assert_equal 1, evidence.instance_variable_get(:@owner_associations_count)
  end

  def test_false_test_id_does_not_collide_with_attributed_string_test_id
    evidence = Branchproof::Evidence.new(inventory: @inventory, limits: @limits, run_id: "run")
    evidence.register_test(test: { id: "false", name: "false", adapter: "test" })
    assert_equal "recorded", evidence.record(execution: execution(test_id: false)).fetch(:status)
    assert_equal "recorded", evidence.record(execution: execution(test_id: "false")).fetch(:status)
    vector = evidence.snapshot.fetch(:vectors).fetch(0)
    assert_equal 2, vector.fetch(:count)
    assert_equal 1, vector.fetch(:unattributed_count)
    assert_equal ["false"], vector.fetch(:test_ids)
  end
end
