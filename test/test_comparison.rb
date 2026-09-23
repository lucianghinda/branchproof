# frozen_string_literal: true

require "test_helper"
require "branchproof/comparison"

class TestComparison < Minitest::Test
  def document(status:, digest: "digest", run_metadata: {}, completeness: nil, vectors: nil, tests: nil,
               source_inventory: nil, analysis_status: nil, baseline_status: "PASSED")
    vectors ||= [
      { id: "v1", decision_id: "d1", values: [true, true], outcome: true, test_ids: ["t1"] },
      { id: "v2", decision_id: "d1", values: [false, true], outcome: false, test_ids: ["t2"] }
    ]
    tests ||= [
      { id: "t1", adapter: "minitest", class_name: "DecisionTest", method_name: "test_true",
        source: { relative_path: "test/decision_test.rb", line: 8 } },
      { id: "t2", adapter: "minitest", class_name: "DecisionTest", method_name: "test_false",
        source: { relative_path: "test/decision_test.rb", line: 12 } }
    ]
    source_inventory ||= { source_units: [{ source_id: "s1", relative_path: "lib/decision.rb", digest: digest }],
                           decisions: [{ id: "d1", source_id: "s1", expression: "left && right", line: 4,
                                         conditions: [{ id: "c1", index: 0, expression: "left", byte_start: 0,
                                                        byte_length: 4 },
                                                      { id: "c2", index: 1, expression: "right", byte_start: 9,
                                                        byte_length: 5 }] }] }
    analysis_status ||= status
    completeness ||= { observation: true, attribution: true, analysis: true }
    {
      schema_version: "1.1", criterion_version: "masking_occurrence_v1",
      source_inventory: source_inventory,
      observations: { run_ids: ["run"], vectors: vectors, tests: tests,
                      completeness: { observation: true, attribution: true, analysis: true } },
      analysis: { decisions: [{ decision_id: "d1", condition_results: [
        { condition_id: "c1", status: analysis_status, canonical_pair: %w[v1 v2] },
        { condition_id: "c2", status: "NOT_PROVEN" }
      ] }], completeness: { observation: true, attribution: true, analysis: true } },
      baseline: { status: baseline_status, finalized: true },
      completeness: completeness,
      runtime: "ruby-3.4",
      run_metadata: { project_kind: "ruby", source_patterns: ["lib/**/*.rb"], test_patterns: ["test/**/*_test.rb"],
                      test_files: ["test/decision_test.rb"], runner_args: [], limits: {}, **run_metadata }
    }
  end

  def test_lost_proof_is_reported_with_previous_witness
    before = document(status: "PROVEN")
    after = document(status: "NOT_PROVEN")
    result = Branchproof::Comparison.new(before: before, after: after).call

    lost = result.fetch("changes").find { |change| change["condition_id"] == "c1" }
    assert_equal "lost proof", lost.fetch("change")
    assert_equal "lib/decision.rb", lost.fetch("relative_path")
    assert_equal "DecisionTest#test_true (test/decision_test.rb:8)", lost.dig("previous_witness", 0, "tests", 0)
    assert_equal 1, result.fetch("regressions")
    assert_equal "complete", result.fetch("status")
  end

  def test_changed_source_is_incomplete_and_has_no_condition_delta
    result = Branchproof::Comparison.new(before: document(status: "PROVEN"), after: document(status: "NOT_PROVEN", digest: "changed")).call

    assert_equal "comparison incomplete", result.fetch("status")
    assert_empty result.fetch("changes")
    assert_equal "lib/decision.rb", result.dig("changed_sources", 0, "relative_path")
  end

  def test_seed_changes_do_not_make_runs_incomparable
    before = document(status: "NOT_PROVEN", run_metadata: { runner_args: ["--seed", "1", "--verbose"] })
    after = document(status: "NOT_PROVEN", run_metadata: { runner_args: ["--seed", "2", "--verbose"] })

    refute_includes Branchproof::Comparison.new(before: before, after: after).call.fetch("reasons"), "runner_args differs"
  end

  def test_missing_exclusion_metadata_is_equivalent_to_empty_scope
    before = document(status: "PROVEN")
    after = document(status: "PROVEN", run_metadata: { exclude_patterns: [] })

    result = Branchproof::Comparison.new(before: before, after: after).call

    refute_includes result.fetch("reasons"), "source exclusion scope differs"
  end

  def test_changed_exclusion_scope_is_reported_as_a_comparability_reason
    before = document(status: "PROVEN", run_metadata: { exclude_patterns: ["app/generated/**/*.rb"] })
    after = document(status: "PROVEN", run_metadata: { exclude_patterns: ["app/legacy/**/*.rb"] })

    result = Branchproof::Comparison.new(before: before, after: after).call

    assert_includes result.fetch("reasons"), "source exclusion scope differs"
  end

  def test_missing_metadata_and_nested_incompleteness_are_incomplete
    missing = document(status: "PROVEN").dup
    missing.delete(:run_metadata)
    result = Branchproof::Comparison.new(before: missing, after: document(status: "PROVEN")).call
    assert_equal "comparison incomplete", result.fetch("status")
    incomplete = document(status: "PROVEN").merge(completeness: { observation: true, attribution: true, analysis: false })
    assert_equal "comparison incomplete", Branchproof::Comparison.new(before: incomplete, after: document(status: "PROVEN")).call.fetch("status")
  end

  def test_missing_nested_completeness_fields_are_incomplete
    incomplete = document(status: "PROVEN", completeness: { observation: true, attribution: true })

    result = Branchproof::Comparison.new(before: incomplete, after: document(status: "PROVEN")).call

    assert_equal "comparison incomplete", result.fetch("status")
    assert_includes result.fetch("reasons"), "run baselines are not successful finalized complete reports"
  end

  def test_analysis_absence_is_incomplete_even_when_baseline_is_finalized
    incomplete = document(status: "PROVEN").dup
    incomplete.delete(:analysis)

    result = Branchproof::Comparison.new(before: incomplete, after: document(status: "PROVEN")).call

    assert_equal "comparison incomplete", result.fetch("status")
  end

  def test_failed_baseline_is_incomplete
    result = Branchproof::Comparison.new(before: document(status: "PROVEN", baseline_status: "ERROR"),
                                         after: document(status: "PROVEN")).call

    assert_equal "comparison incomplete", result.fetch("status")
  end

  def test_runner_filter_limits_and_runtime_differences_are_context_reasons
    before = document(status: "PROVEN", run_metadata: {
                        runner_args: ["--name", "/one/"], limits: { exact_candidates: 10 }, runtime: { ruby: "3.4" }
                      })
    after = document(status: "PROVEN", run_metadata: {
                       runner_args: ["--name", "/two/"], limits: { exact_candidates: 20 }, runtime: { ruby: "3.5" }
                     })
    reasons = Branchproof::Comparison.new(before: before, after: after).call.fetch("reasons")

    assert_includes reasons, "runner_args differs"
    assert_includes reasons, "limits differs"
    assert_includes reasons, "runtime differs"
  end

  def test_different_test_population_is_allowed_when_discovery_context_matches
    before = document(status: "PROVEN")
    after = document(status: "PROVEN", tests: before.dig(:observations, :tests).first(1),
                     run_metadata: { test_files: ["test/decision_test.rb", "test/new_test.rb"] })

    result = Branchproof::Comparison.new(before: before, after: after).call

    refute_includes result.fetch("reasons"), "test_patterns differs"
    assert_equal "complete", result.fetch("status")
  end

  def test_zero_matches_and_source_population_changes_are_explicit
    no_match = document(status: "PROVEN").merge(source_inventory: { source_units: [], decisions: [] })
    result = Branchproof::Comparison.new(before: no_match, after: document(status: "PROVEN")).call
    assert_includes result.fetch("reasons"), "no comparable conditions"
    after = document(status: "PROVEN").merge(source_inventory: { source_units: [
                                               { source_id: "s1", relative_path: "lib/decision.rb", digest: "digest" },
                                               { source_id: "s2", relative_path: "lib/new.rb", digest: "new" }
                                             ], decisions: document(status: "PROVEN").dig(:source_inventory, :decisions) })
    result = Branchproof::Comparison.new(before: document(status: "PROVEN"), after: after).call
    assert_equal ["lib/new.rb"], result.fetch("newly_in_report")

    removed = document(status: "PROVEN").merge(source_inventory: { source_units: [], decisions: [] })
    result = Branchproof::Comparison.new(before: document(status: "PROVEN"), after: removed).call
    assert_equal ["lib/decision.rb"], result.fetch("no_longer_in_report")
  end

  def test_same_condition_id_with_disagreeing_source_identity_is_not_matched
    after_inventory = document(status: "PROVEN").fetch(:source_inventory).merge(
      source_units: [{ source_id: "different", relative_path: "lib/decision.rb", digest: "digest" }],
      decisions: [document(status: "PROVEN").dig(:source_inventory, :decisions).first.merge(source_id: "different")]
    )

    result = Branchproof::Comparison.new(before: document(status: "PROVEN"),
                                         after: document(status: "PROVEN", source_inventory: after_inventory)).call

    assert_equal 0, result.dig("matching", "matched_conditions")
    assert_includes result.fetch("reasons"), "no comparable conditions"
  end

  def test_test_location_line_shifts_match_unique_owner_and_report_context
    before = document(status: "PROVEN")
    before[:source_inventory][:source_units].first[:absolute_path] = "/old/checkout/lib/decision.rb"
    shifted_tests = before.dig(:observations, :tests).map do |test|
      test.merge(source: test.fetch(:source).merge(line: test.fetch(:source).fetch(:line) + 20))
    end
    after = document(status: "PROVEN", tests: shifted_tests)
    after[:source_inventory][:source_units].first[:absolute_path] = "/new/checkout/lib/decision.rb"

    change = Branchproof::Comparison.new(before: before, after: after).call.fetch("changes").find do |row|
      row.fetch("condition_id") == "c1"
    end
    owner = change.fetch("owner_context").find { |item| item.fetch("label").include?("test_true") }

    assert_equal "present in current run", owner.fetch("test_status")
    assert_equal "observed in current run", owner.fetch("observation_status")
    assert_equal [true, true], owner.fetch("values")
    assert_equal true, owner.fetch("outcome")
    refute_includes change.dig("previous_witness", 0, "tests", 0), "/old/checkout"
  end

  def test_ambiguous_duplicate_test_names_remain_unmatched
    duplicate_tests = [
      { id: "t1", adapter: "minitest", class_name: "DecisionTest", method_name: "test_true",
        source: { relative_path: "test/decision_test.rb", line: 8 } },
      { id: "t2", adapter: "minitest", class_name: "DecisionTest", method_name: "test_true",
        source: { relative_path: "test/decision_test.rb", line: 12 } },
      { id: "t3", adapter: "minitest", class_name: "DecisionTest", method_name: "test_false",
        source: { relative_path: "test/decision_test.rb", line: 16 } }
    ]
    before = document(status: "PROVEN", tests: duplicate_tests)
    after = document(status: "NOT_PROVEN", tests: duplicate_tests)

    change = Branchproof::Comparison.new(before: before, after: after).call.fetch("changes").find do |row|
      row.fetch("condition_id") == "c1"
    end

    owner = change.fetch("owner_context").find { |item| item.fetch("label").include?("test_true") }
    assert_equal "not observed in current run (no unique test match)", owner.fetch("test_status")
    assert_equal "not observed in current run", owner.fetch("observation_status")
  end

  def test_rspec_examples_match_by_relative_path_and_scoped_id_in_unchanged_specs
    tests = [
      { id: "t1", adapter: "rspec", name: "does the thing", example_id: "./spec/policy_spec.rb[1:1]",
        source: { relative_path: "spec/policy_spec.rb", line: 8 } },
      { id: "t2", adapter: "rspec", name: "does the thing", example_id: "./spec/policy_spec.rb[1:2]",
        source: { relative_path: "spec/policy_spec.rb", line: 12 } }
    ]
    tests.each { |test| test.merge!(spec_digest: "spec-revision", source_digest: "spec-revision") }
    before = document(status: "PROVEN", tests: tests)
    after = document(status: "NOT_PROVEN", tests: tests.map { |test| test.merge(id: "new-#{test[:id]}") })
    after[:observations][:vectors].each_with_index { |vector, index| vector[:test_ids] = ["new-t#{index + 1}"] }

    result = Branchproof::Comparison.new(before: before, after: after).call

    assert_equal 1, result.fetch("regressions")
    assert_equal "complete", result.fetch("status")
    assert(result.fetch("changes").first.fetch("owner_context").all? { |owner| owner.fetch("test_status") == "present in current run" })
  end

  def test_rspec_insertions_do_not_match_shifted_scoped_ids
    assert_rspec_revision_unmatched(%w[first second], %w[inserted first second])
  end

  def test_rspec_deletions_do_not_match_shifted_scoped_ids
    assert_rspec_revision_unmatched(%w[first second], %w[second])
  end

  def test_rspec_reordering_warns_even_with_the_same_population_size
    assert_rspec_revision_unmatched(%w[first second], %w[second first])
  end

  def test_rspec_duplicate_descriptions_cannot_identify_examples_in_changed_specs
    assert_rspec_revision_unmatched(%w[same same], %w[same same])
  end

  def test_rspec_shared_definition_changes_make_identity_uncertain
    assert_rspec_revision_unmatched(%w[first second], %w[first second], digest_field: :source_digest)
  end

  def test_rspec_legacy_reports_without_revision_evidence_do_not_claim_identity
    tests = rspec_tests(%w[first second], "unchanged").map { |test| test.except(:spec_digest, :source_digest) }
    result = Branchproof::Comparison.new(before: document(status: "PROVEN", tests: tests),
                                         after: document(status: "NOT_PROVEN", tests: tests)).call

    assert(result.fetch("changes").first.fetch("owner_context").all? { |owner| owner.fetch("test_status").include?("no unique test match") })
    assert(result.fetch("context").any? { |message| message.include?("RSpec example identity is uncertain") })
  end

  def test_rspec_duplicate_scoped_ids_are_ambiguous_instead_of_matching
    tests = 2.times.map do |index|
      { id: "t#{index + 1}", adapter: "rspec", name: "same description",
        spec_digest: "unchanged", source_digest: "unchanged",
        example_id: "./spec/policy_spec.rb[1:1]", source: { relative_path: "spec/policy_spec.rb", line: 8 + index } }
    end
    before = document(status: "PROVEN", tests: tests)
    after = document(status: "NOT_PROVEN", tests: tests)

    owner = Branchproof::Comparison.new(before: before, after: after).call.fetch("changes").first
                                   .fetch("owner_context").find { |item| item.fetch("label").include?("same description") }
    assert_includes owner.fetch("test_status"), "no unique test match"
  end

  def test_framework_changes_are_context_reasons_before_regression_is_considered
    before = document(status: "PROVEN", run_metadata: { framework: "rspec", framework_version: "3.13" })
    after = document(status: "NOT_PROVEN", run_metadata: { framework: "minitest", framework_version: "5.20" })

    result = Branchproof::Comparison.new(before: before, after: after).call

    assert_includes result.fetch("reasons"), "framework differs"
    refute result.fetch("regression")
  end

  def test_rspec_example_ids_normalize_checkout_roots
    tests_before = [{ id: "old", adapter: "rspec", name: "same", example_id: "/old/spec/policy_spec.rb[1:1]",
                      source: { path: "/old/spec/policy_spec.rb", line: 8 } }]
    tests_after = [{ id: "new", adapter: "rspec", name: "same", example_id: "/new/spec/policy_spec.rb[1:1]",
                     source: { path: "/new/spec/policy_spec.rb", line: 8 } }]
    (tests_before + tests_after).each { |test| test.merge!(spec_digest: "unchanged", source_digest: "unchanged") }
    before = document(status: "PROVEN", tests: tests_before).tap do |item|
      item[:source_inventory][:root] = "/old"
      item[:run_metadata][:project_root] = "/old"
      item[:observations][:vectors].each { |vector| vector[:test_ids] = ["old"] }
    end
    after = document(status: "NOT_PROVEN", tests: tests_after).tap do |item|
      item[:source_inventory][:root] = "/new"
      item[:run_metadata][:project_root] = "/new"
      item[:observations][:vectors].each { |vector| vector[:test_ids] = ["new"] }
    end

    result = Branchproof::Comparison.new(before: before, after: after).call

    assert_equal "complete", result.fetch("status")
    assert_equal 1, result.fetch("regressions")
    assert(result.fetch("changes").first.fetch("owner_context").all? { |owner| owner.fetch("test_status") == "present in current run" })
  end

  def test_owner_observation_requires_matching_values_and_outcome
    before = document(status: "PROVEN")
    altered_vectors = [
      { id: "v1", decision_id: "d1", values: [true, false], outcome: false, test_ids: ["t1"] },
      { id: "v2", decision_id: "d1", values: [false, true], outcome: false, test_ids: ["t2"] }
    ]
    after = document(status: "NOT_PROVEN", vectors: altered_vectors)

    owner = Branchproof::Comparison.new(before: before, after: after).call.fetch("changes").first
                                   .fetch("owner_context").find { |item| item.fetch("label").include?("test_true") }
    assert_equal "present in current run", owner.fetch("test_status")
    assert_equal "not observed in current run", owner.fetch("observation_status")
  end

  private

  def assert_rspec_revision_unmatched(before_names, after_names, digest_field: :spec_digest)
    before_tests = rspec_tests(before_names, "old")
    after_tests = rspec_tests(after_names, "old").map { |test| test.merge(digest_field => "new") }
    result = Branchproof::Comparison.new(before: document(status: "PROVEN", tests: before_tests),
                                         after: document(status: "NOT_PROVEN", tests: after_tests)).call

    owners = result.fetch("changes").first.fetch("owner_context")
    assert owners.all? { |owner| owner.fetch("test_status").include?("no unique test match") }, owners.inspect
    assert(owners.all? { |owner| owner.fetch("observation_status") == "not observed in current run" })
    assert_includes result.fetch("context"), "test population differs"
  end

  def rspec_tests(names, digest)
    names.each_with_index.map do |name, index|
      { id: "t#{index + 1}", adapter: "rspec", name: name, example_id: "./spec/policy_spec.rb[1:#{index + 1}]",
        spec_digest: digest, source_digest: digest, source: { relative_path: "spec/policy_spec.rb", line: 8 + index } }
    end
  end
end
