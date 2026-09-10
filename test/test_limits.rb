# frozen_string_literal: true

require "test_helper"

class TestLimits < Minitest::Test
  def test_defaults_are_positive_and_frozen
    limits = Branchproof::Limits.default
    assert_equal %i[conditions_per_decision vectors_per_decision owner_associations_per_run tests_per_run exact_candidates exact_search_nodes constraint_search_states].sort,
                 limits.keys.sort
    assert(limits.values.all? { |value| value.is_a?(Integer) && value.positive? })
    assert_predicate limits, :frozen?
  end

  def test_normalize_applies_known_overrides
    limits = Branchproof::Limits.normalize(conditions_per_decision: 2)
    assert_equal 2, limits[:conditions_per_decision]
    assert_equal Branchproof::Limits.default[:tests_per_run], limits[:tests_per_run]
  end

  def test_normalize_rejects_unknown_or_non_positive_values
    assert_raises(ArgumentError) { Branchproof::Limits.normalize(nope: 1) }
    assert_raises(ArgumentError) { Branchproof::Limits.normalize(exact_candidates: 0) }
  end
end
