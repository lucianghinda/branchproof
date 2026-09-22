# frozen_string_literal: true

require "test_helper"
require "branchproof/evidence"

class TestEvidence < Minitest::Test
  def inventory
    { digest: "inventory", source_digests: { "a.rb" => "digest" },
      decisions: [{ id: "d", conditions: [{ index: 0 }, { index: 1 }],
                    tree: { type: :and, left: { type: :atom, index: 0 }, right: { type: :atom, index: 1 } } }] }
  end

  def test_groups_vectors_and_retains_owner_provenance
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "run")
    evidence.register_test(test: { id: "t", name: "test_x", adapter: "fake" })
    result = evidence.record(execution: { run_id: "run", execution_id: "e", decision_id: "d",
                                          test_id: "t", phase: "body", owner: {}, observations: [[0, true], [1, false]], outcome: false,
                                          status: "completed" })
    assert_equal "recorded", result[:status]
    vector = evidence.snapshot[:vectors].fetch(0)
    assert_equal [true, false], vector[:values]
    assert_equal ["t"], vector[:test_ids]
  end

  def test_phase_counts_are_an_immutable_copy_without_snapshotting_vectors
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "run")
    evidence.register_test(test: { id: "t", name: "test_x", adapter: "fake" })
    execution = { run_id: "run", execution_id: "e", decision_id: "d", test_id: "t", phase: "body",
                  owner: {}, observations: [[0, true], [1, false]], outcome: false, status: "completed" }
    evidence.record(execution: execution)
    counts = evidence.test_phase_counts
    assert_equal({ "t" => { "body" => 1 } }, counts)
    assert_raises(FrozenError) { counts.fetch("t")["body"] = 7 }
    evidence.record(execution: execution.merge(execution_id: "e2"))
    assert_equal 1, counts.fetch("t").fetch("body")
    assert_equal 2, evidence.test_phase_counts.fetch("t").fetch("body")
  end

  def test_merge_rejects_incompatible_source_without_mutating
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "run")
    snapshot = evidence.snapshot.merge(source_digests: { "a.rb" => "other" }, run_ids: ["other"])
    result = evidence.merge(snapshot: snapshot)
    assert_equal "rejected", result[:status]
    assert_empty evidence.snapshot[:vectors]
  end

  def test_merging_two_compatible_snapshots_sums_shared_test_phase_counts
    first = evidence_for_run("first", test_id: "shared", repetitions: 2)
    second = evidence_for_run("second", test_id: "shared", repetitions: 2)
    target = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "target")

    assert_equal "merged", target.merge(snapshot: first.snapshot)[:status]
    assert_equal "merged", target.merge(snapshot: second.snapshot)[:status]
    assert_equal 4, target.snapshot.dig(:vectors, 0, :count)
    assert_equal({ "body" => 4 }, target.snapshot.dig(:tests, 0, :phase_counts))
  end

  def test_merging_snapshot_sums_with_local_test_phase_counts
    target = evidence_for_run("target", test_id: "shared", repetitions: 2)
    source = evidence_for_run("source", test_id: "shared", repetitions: 2)

    assert_equal "merged", target.merge(snapshot: source.snapshot)[:status]
    assert_equal 4, target.snapshot.dig(:vectors, 0, :count)
    assert_equal({ "body" => 4 }, target.snapshot.dig(:tests, 0, :phase_counts))
  end

  def test_merging_json_roundtrip_sums_shared_test_phase_counts
    source = evidence_for_run("source", test_id: "shared", repetitions: 2)
    target = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "target")

    snapshot = JSON.parse(JSON.generate(source.snapshot))
    assert_equal "merged", target.merge(snapshot: snapshot)[:status]
    assert_equal({ "body" => 2 }, target.snapshot.dig(:tests, 0, :phase_counts))
  end

  def test_merging_identical_snapshot_twice_does_not_double_count_test_phases
    source = evidence_for_run("source", test_id: "shared", repetitions: 2)
    target = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "target")

    assert_equal "merged", target.merge(snapshot: source.snapshot)[:status]
    assert_equal "merged", target.merge(snapshot: source.snapshot)[:status]
    assert_equal 2, target.snapshot.dig(:vectors, 0, :count)
    assert_equal({ "body" => 2 }, target.snapshot.dig(:tests, 0, :phase_counts))
  end

  def test_conflicting_snapshot_for_existing_run_id_does_not_mutate_test_phases
    source = evidence_for_run("source", test_id: "shared", repetitions: 2)
    target = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "target")
    assert_equal "merged", target.merge(snapshot: source.snapshot)[:status]
    before = target.snapshot
    conflicting = source.snapshot.merge(tests: [source.snapshot[:tests].first.merge(phase_counts: { "body" => 99 })])

    assert_equal "rejected", target.merge(snapshot: conflicting)[:status]
    assert_equal before, target.snapshot
  end

  def test_merging_snapshot_sums_each_normalized_lifecycle_phase_independently
    first = evidence_for_run("first", test_id: "shared", phase_counts: { setup: 2, body: 2, teardown: 2 })
    second = evidence_for_run("second", test_id: "shared", phase_counts: { setup: 2, body: 2, teardown: 2 })
    target = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "target")

    assert_equal "merged", target.merge(snapshot: first.snapshot)[:status]
    assert_equal "merged", target.merge(snapshot: second.snapshot)[:status]
    assert_equal({ "setup" => 4, "body" => 4, "teardown" => 4 }, target.snapshot.dig(:tests, 0, :phase_counts))
  end

  def test_snapshot_is_an_immutable_deep_copy
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "run")
    evidence.record(execution: { run_id: "run", execution_id: "e", decision_id: "d", test_id: nil, phase: "body",
                                 owner: {}, observations: [[0, true], [1, false]], outcome: false, status: "completed" })
    snapshot = evidence.snapshot
    assert_predicate snapshot, :frozen?
    assert_predicate snapshot[:vectors].first[:values], :frozen?
    assert_raises(FrozenError) { snapshot[:vectors].first[:values] << true }
  end

  def test_snapshot_metadata_uses_package_version
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "run")

    snapshot = evidence.snapshot

    assert_equal Branchproof::VERSION, snapshot[:tool_version]
    assert_equal Branchproof::Evidence::SCHEMA_VERSION, snapshot[:schema_version]
    assert_equal Branchproof::Evidence::CRITERION_VERSION, snapshot[:criterion_version]
  end

  def test_rejects_trace_that_does_not_match_short_circuit_tree
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "run")
    result = evidence.record(execution: { run_id: "run", execution_id: "bad", decision_id: "d", test_id: nil, phase: "body",
                                          owner: {}, observations: [[0, false], [1, true]], outcome: false, status: "completed" })
    assert_equal "rejected", result[:status]
    assert_empty evidence.snapshot[:vectors]
  end

  def test_aborted_trace_is_counted_without_creating_a_vector
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "run")
    result = evidence.record(execution: { run_id: "run", execution_id: "abort", decision_id: "d", test_id: nil, phase: "body",
                                          owner: {}, observations: [[0, true]], outcome: nil, status: "aborted" })
    assert_equal "recorded", result[:status]
    assert_equal({ "d" => 1 }, evidence.snapshot[:abort_counts])
    assert_empty evidence.snapshot[:vectors]
  end

  def test_limits_mark_snapshot_incomplete
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: { vectors_per_decision: 1 }, run_id: "run")
    first = { run_id: "run", execution_id: "one", decision_id: "d", test_id: nil, phase: "body",
              owner: {}, observations: [[0, true], [1, true]], outcome: true, status: "completed" }
    second = first.merge(execution_id: "two", observations: [[0, false]], outcome: false)
    assert_equal "recorded", evidence.record(execution: first)[:status]
    assert_equal "limited", evidence.record(execution: second)[:status]
    refute evidence.snapshot[:completeness][:observation]
  end

  def test_repeated_execution_by_existing_owner_does_not_consume_owner_limit
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: { owner_associations_per_run: 1 }, run_id: "run")
    execution = { run_id: "run", execution_id: "one", decision_id: "d", test_id: "t", phase: "body", owner: {},
                  observations: [[0, true], [1, false]], outcome: false, status: "completed" }
    assert_equal "recorded", evidence.record(execution: execution)[:status]
    assert_equal "recorded", evidence.record(execution: execution.merge(execution_id: "two"))[:status]
    assert evidence.snapshot[:completeness][:attribution]
  end

  def test_merge_is_atomic_when_a_later_vector_is_malformed
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "main")
    source = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "worker")
    source.record(execution: { run_id: "worker", execution_id: "e", decision_id: "d", test_id: nil, phase: "body",
                               owner: {}, observations: [[0, true], [1, true]], outcome: true, status: "completed" })
    snapshot = source.snapshot
    malformed = snapshot.merge(vectors: snapshot[:vectors] + [{ id: "bad", decision_id: "d", values: [true, false],
                                                                outcome: false, count: 1, test_ids: [], phases_by_test: {}, unattributed_count: 0 }])
    assert_equal "rejected", evidence.merge(snapshot: malformed)[:status]
    assert_empty evidence.snapshot[:vectors]
  end

  def test_merging_same_snapshot_twice_is_idempotent
    source = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "worker")
    source.record(execution: { run_id: "worker", execution_id: "e", decision_id: "d", test_id: nil, phase: "body",
                               owner: {}, observations: [[0, true], [1, true]], outcome: true, status: "completed" })
    target = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "main")
    snapshot = source.snapshot
    assert_equal "merged", target.merge(snapshot: snapshot)[:status]
    before = target.snapshot
    assert_equal "merged", target.merge(snapshot: snapshot)[:status]
    assert_equal before, target.snapshot
  end

  def test_ambiguous_overlap_is_rejected_before_owner_limit_is_applied
    source = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "worker")
    source.record(execution: { run_id: "worker", execution_id: "one", decision_id: "d", test_id: nil, phase: "body",
                               owner: {}, observations: [[0, true], [1, true]], outcome: true, status: "completed" })
    target = Branchproof::Evidence.new(inventory: inventory, limits: { owner_associations_per_run: 1 }, run_id: "main")
    assert_equal "merged", target.merge(snapshot: source.snapshot)[:status]

    source.record(execution: { run_id: "worker", execution_id: "two", decision_id: "d", test_id: nil, phase: "body",
                               owner: {}, observations: [[0, false], [1, true]], outcome: false, status: "completed" })
    result = target.merge(snapshot: source.snapshot)

    assert_equal "rejected", result[:status]
    assert_equal 1, target.snapshot[:vectors].length
  end

  def test_inventory_identity_ignores_root_absolute_path_and_source_bytes
    base = inventory.merge(root: "/worker",
                           source_units: [{ relative_path: "a.rb", absolute_path: "/worker/a.rb", digest: "digest",
                                            original_bytes: "#{0xc3.chr}#{0xa9.chr}" }])
    rebuilt = base.merge(root: "/parent",
                         source_units: [{ relative_path: "a.rb",
                                          absolute_path: "/parent/a.rb", digest: "digest", original_bytes: "different" }])
    left = Branchproof::Evidence.new(inventory: base, limits: {}, run_id: "left")
    right = Branchproof::Evidence.new(inventory: rebuilt, limits: {}, run_id: "right")
    assert_equal "merged", right.merge(snapshot: left.snapshot)[:status]
  end

  def test_malformed_merge_returns_rejection_without_mutating
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "run")
    before = evidence.snapshot
    result = evidence.merge(snapshot: nil)
    assert_equal "rejected", result[:status]
    assert_equal before, evidence.snapshot
  end

  def test_missing_snapshot_fields_are_rejected_before_any_merge_state_changes
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "run")
    before = evidence.snapshot
    malformed = before.except(:completeness)
    result = evidence.merge(snapshot: malformed)
    assert_equal "rejected", result[:status]
    assert_equal before, evidence.snapshot
  end

  def test_negative_or_string_unattributed_counts_are_rejected
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "run")
    source = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "source")
    source.record(execution: { run_id: "source", execution_id: "e", decision_id: "d", test_id: nil, phase: "body",
                               owner: {}, observations: [[0, true], [1, true]], outcome: true, status: "completed" })
    snapshot = source.snapshot
    vector = snapshot[:vectors].first.merge(unattributed_count: -1)
    assert_equal "rejected", evidence.merge(snapshot: snapshot.merge(vectors: [vector]))[:status]
    assert_empty evidence.snapshot[:vectors]
    vector = snapshot[:vectors].first.merge(unattributed_count: "0")
    assert_equal "rejected", evidence.merge(snapshot: snapshot.merge(vectors: [vector]))[:status]
  end

  def test_zero_vector_count_is_rejected_atomically
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "run")
    source = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: "source")
    source.record(execution: { run_id: "source", execution_id: "e", decision_id: "d", test_id: nil, phase: "body",
                               owner: {}, observations: [[0, true], [1, true]], outcome: true, status: "completed" })
    snapshot = source.snapshot
    vector = snapshot[:vectors].first.merge(count: 0, unattributed_count: 0)
    result = evidence.merge(snapshot: snapshot.merge(vectors: [vector]))
    assert_equal "rejected", result[:status]
    assert_empty evidence.snapshot[:vectors]
  end

  private

  def evidence_for_run(run_id, test_id:, repetitions: 1, phase_counts: nil)
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: {}, run_id: run_id)
    evidence.register_test(test: { id: test_id, name: test_id, adapter: "fake", phase_counts: phase_counts || {} })
    if phase_counts.nil?
      repetitions.times do |index|
        evidence.record(execution: { run_id: run_id, execution_id: "#{run_id}-#{index}", decision_id: "d",
                                     test_id: test_id, phase: "body", owner: {}, observations: [[0, true], [1, false]],
                                     outcome: false, status: "completed" })
      end
    end
    evidence
  end
end
