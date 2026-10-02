# frozen_string_literal: true

require_relative "coverage_summary"

# rubocop:disable-next Metrics/ModuleLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
module Branchproof
  # Computes informational coverage for the current decisions captured by a changed scope.
  module ChangedCoverage
    CRITERIA = {
      decision: %i[covered_decisions supported_decisions],
      condition: %i[covered_values required_values],
      condition_decision: %i[covered_decisions supported_decisions],
      mcdc: %i[proven_conditions supported_conditions],
      decision_table: %i[covered_rules required_rules],
      alternative: %i[covered_alternatives required_alternatives]
    }.freeze
    COMPLETENESS_FIELDS = %i[observation attribution analysis].freeze

    module_function

    def call(document:, scope:)
      ids = Array(value(scope, :decision_ids))
      scope_status = value(scope, :status)
      decisions = analysis_decisions(document)
      by_id = decisions.to_h { |decision| [value(decision, :decision_id), decision] }
      selected = ids.filter_map { |id| by_id[id] }
      supported_count = selected.count { |decision| !value(decision, :unsupported) }
      unsupported_count = selected.length - supported_count
      reason = unavailable_reason(document, scope, ids, selected)
      usable = selected.select do |decision|
        value(decision, :unsupported) || complete_decision_coverage?(decision)
      end
      summary = CoverageSummary.call(usable)

      {
        scope_status: scope_status,
        status: reason ? "unavailable" : "available",
        reason: reason,
        selected_decisions: ids.length,
        supported_decisions: supported_count,
        unsupported_decisions: unsupported_count,
        coverage: coverage_rows(summary, reason)
      }
    end

    def unavailable_reason(document, scope, ids, selected)
      return "invalid_scope" unless scope.is_a?(Hash) && %w[complete empty].include?(value(scope, :status))
      return "invalid_scope" if (value(scope, :status) == "empty") != ids.empty?
      return "empty_scope" if ids.empty?
      return "missing_selected_analysis" unless selected.length == ids.length
      return "unsupported_only" if selected.all? { |decision| value(decision, :unsupported) }
      return "missing_selected_coverage" unless selected.all? do |decision|
        value(decision, :unsupported) || complete_decision_coverage?(decision)
      end
      return "baseline_unavailable" unless successful_baseline?(document)
      return "incomplete_document" unless complete?(value(document, :completeness))

      observations = value(document, :observations) || value(document, :evidence)
      return "incomplete_observations" if incomplete_section?(observations)

      analysis = value(document, :analysis)
      return "analysis_unavailable" unless analysis.is_a?(Hash)
      return "incomplete_analysis" if incomplete_section?(analysis)

      nil
    end
    private_class_method :unavailable_reason

    def complete_decision_coverage?(decision)
      coverage = value(decision, :coverage)
      return false unless coverage.is_a?(Hash)

      if alternative_decision?(decision)
        alternative = value(coverage, :alternative)
        mcdc = value(coverage, :mcdc)
        return false unless alternative.is_a?(Hash) && integer_count?(value(alternative, :covered_alternatives)) &&
                            integer_count?(value(alternative, :required_alternatives)) &&
                            value(mcdc, :status) == "not_applicable"

        value(alternative, :covered_alternatives) <= value(alternative, :required_alternatives)
      else
        rows = %i[decision condition condition_decision mcdc decision_table].map { |key| value(coverage, key) }
        return false unless rows.all?(Hash)
        return false unless value(value(coverage, :decision), :status).is_a?(String)
        return false unless value(value(coverage, :condition_decision), :status).is_a?(String)
        return false unless %i[covered_values condition_count covered_conditions].all? do |key|
          integer_count?(value(value(coverage, :condition), key))
        end
        return false unless integer_count?(value(value(coverage, :mcdc), :proven_conditions))

        condition_count = value(value(coverage, :condition), :condition_count)
        return false if value(value(coverage, :condition), :covered_values) > condition_count * 2
        return false if value(value(coverage, :condition), :covered_conditions) > condition_count
        return false if value(value(coverage, :mcdc), :proven_conditions) > condition_count
        return false unless value(value(coverage, :decision_table), :status).is_a?(String)

        table = value(decision, :decision_table)
        return false unless table.is_a?(Hash) && %w[calculated not_calculated].include?(value(table, :status))
        return true if value(table, :status) == "not_calculated"

        valid_counts = %i[covered_rules required_rules generated_rules impossible_rules].all? do |key|
          integer_count?(value(table, key))
        end
        return false unless valid_counts

        covered = value(table, :covered_rules)
        required = value(table, :required_rules)
        generated = value(table, :generated_rules)
        impossible = value(table, :impossible_rules)
        covered <= required && required + impossible == generated && value(table, :coverage_status).is_a?(String)
      end
    end
    private_class_method :complete_decision_coverage?

    def alternative_decision?(decision)
      kind = value(decision, :kind).to_s
      !kind.empty? && kind != "boolean"
    end
    private_class_method :alternative_decision?

    def integer_count?(value)
      value.is_a?(Integer) && value >= 0
    end
    private_class_method :integer_count?

    def coverage_rows(summary, overall_reason)
      CRITERIA.to_h do |criterion, (numerator_key, denominator_key)|
        aggregate = value(summary, criterion) || {}
        numerator = value(aggregate, numerator_key)
        denominator = value(aggregate, denominator_key)
        reason = overall_reason
        reason ||= "decision_table_not_calculated" if criterion == :decision_table &&
                                                      value(aggregate, :not_calculated_decisions).to_i.positive?
        reason ||= "zero_denominator" if denominator.to_i.zero?
        [criterion, { numerator: numerator, denominator: denominator,
                      percentage: reason ? nil : value(aggregate, :percentage),
                      status: reason ? "unavailable" : "available", reason: reason }]
      end
    end
    private_class_method :coverage_rows

    def successful_baseline?(document)
      baseline = value(document, :baseline)
      value(baseline, :status).to_s.upcase == "PASSED" && value(baseline, :finalized) == true
    end
    private_class_method :successful_baseline?

    def complete?(completeness)
      completeness.is_a?(Hash) && COMPLETENESS_FIELDS.all? { |field| value(completeness, field) == true }
    end
    private_class_method :complete?

    def incomplete_section?(section)
      !section.is_a?(Hash) || !key_present?(section, :completeness) || !complete?(value(section, :completeness))
    end
    private_class_method :incomplete_section?

    def analysis_decisions(document)
      Array(value(value(document, :analysis), :decisions))
    end
    private_class_method :analysis_decisions

    def value(hash, key)
      return nil unless hash.respond_to?(:key?)
      return hash[key] if hash.key?(key)

      alternate = key.is_a?(Symbol) ? key.to_s : key.to_sym
      hash[alternate] if hash.key?(alternate)
    end
    private_class_method :value

    def key_present?(hash, key)
      hash.key?(key) || hash.key?(key.to_s) || hash.key?(key.to_sym)
    end
    private_class_method :key_present?
  end
end
