# frozen_string_literal: true

module Branchproof
  # Defines bounded storage and search limits for one analysis.
  module Limits
    KEYS = %i[
      conditions_per_decision vectors_per_decision owner_associations_per_run
      tests_per_run exact_candidates exact_search_nodes constraint_search_states
    ].freeze
    DEFAULTS = {
      conditions_per_decision: 64,
      vectors_per_decision: 8192,
      owner_associations_per_run: 200_000,
      tests_per_run: 50_000,
      exact_candidates: 32,
      exact_search_nodes: 100_000,
      constraint_search_states: 10_000
    }.freeze

    module_function

    def default
      Records.build(DEFAULTS)
    end

    def normalize(overrides = {})
      raise ArgumentError, "limits must be a Hash" unless overrides.is_a?(Hash)

      normalized_overrides = overrides.each_with_object({}) do |(key, value), result|
        raise ArgumentError, "limit keys must be Symbols or Strings" unless key.is_a?(String) || key.is_a?(Symbol)

        result[key.to_sym] = value
      end
      values = DEFAULTS.merge(normalized_overrides)
      unknown = values.keys - KEYS
      raise ArgumentError, "unknown limit: #{unknown.first}" unless unknown.empty?

      values.each do |key, value|
        raise ArgumentError, "#{key} must be a positive Integer" unless value.is_a?(Integer) && value.positive?
      end
      Records.build(values)
    end
  end
end
