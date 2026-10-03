# frozen_string_literal: true

require_relative "decision_table"

# rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
module Branchproof
  # Totals per-decision analyzer coverage without changing its counting rules.
  module CoverageSummary
    module_function

    def call(decisions)
      supported = decisions.reject { |decision| value(decision, :unsupported) }
      boolean_supported = supported.reject { |decision| alternative_decision?(decision) }
      decision_covered = boolean_supported.count do |decision|
        value(value(decision, :coverage), :decision)&.then { value(_1, :status) } == "covered"
      end
      condition_decision_covered = boolean_supported.count do |decision|
        value(value(decision, :coverage), :condition_decision)&.then { value(_1, :status) } == "covered"
      end
      condition_count = boolean_supported.sum do |decision|
        value(value(decision, :coverage), :condition)&.then { value(_1, :condition_count) }.to_i
      end
      condition_values = boolean_supported.sum do |decision|
        value(value(decision, :coverage), :condition)&.then { value(_1, :covered_values) }.to_i
      end
      covered_conditions = boolean_supported.sum do |decision|
        value(value(decision, :coverage), :condition)&.then { value(_1, :covered_conditions) }.to_i
      end
      proven = boolean_supported.sum do |decision|
        value(value(decision, :coverage), :mcdc)&.then { value(_1, :proven_conditions) }.to_i
      end
      {
        decision: { covered_decisions: decision_covered, supported_decisions: boolean_supported.length,
                    percentage: DecisionTable.percentage(decision_covered, boolean_supported.length) },
        condition: { covered_values: condition_values, required_values: condition_count * 2,
                     covered_conditions: covered_conditions, condition_count: condition_count,
                     percentage: DecisionTable.percentage(condition_values, condition_count * 2) },
        condition_decision: { covered_decisions: condition_decision_covered,
                              supported_decisions: boolean_supported.length,
                              percentage: DecisionTable.percentage(condition_decision_covered,
                                                                   boolean_supported.length) },
        mcdc: { proven_conditions: proven, supported_conditions: condition_count,
                percentage: DecisionTable.percentage(proven, condition_count) },
        decision_table: decision_table_aggregate(boolean_supported),
        alternative: alternative_aggregate(decisions)
      }
    end

    def decision_table_aggregate(boolean_supported)
      analyzed = boolean_supported.select do |decision|
        value(value(decision, :decision_table), :status) == "calculated"
      end
      not_calculated = boolean_supported.length - analyzed.length
      covered = analyzed.sum { |decision| value(value(decision, :decision_table), :covered_rules).to_i }
      required = analyzed.sum { |decision| value(value(decision, :decision_table), :required_rules).to_i }
      generated = analyzed.sum { |decision| value(value(decision, :decision_table), :generated_rules).to_i }
      impossible = analyzed.sum { |decision| value(value(decision, :decision_table), :impossible_rules).to_i }
      fully_covered = analyzed.count do |decision|
        value(value(decision, :decision_table), :coverage_status) == "covered"
      end
      { decisions_analyzed: analyzed.length, not_calculated_decisions: not_calculated,
        fully_covered_decisions: fully_covered, covered_rules: covered, required_rules: required,
        generated_rules: generated, impossible_rules: impossible,
        percentage: DecisionTable.percentage(covered, required),
        decision_percentage: DecisionTable.percentage(fully_covered, analyzed.length) }
    end

    def alternative_aggregate(decisions)
      flow = decisions.select { |decision| !value(decision, :unsupported) && alternative_decision?(decision) }
      required = flow.sum do |decision|
        value(value(value(decision, :coverage), :alternative), :required_alternatives).to_i
      end
      covered = flow.sum do |decision|
        value(value(value(decision, :coverage), :alternative), :covered_alternatives).to_i
      end
      { covered_alternatives: covered, required_alternatives: required,
        supported_decisions: flow.length, percentage: DecisionTable.percentage(covered, required) }
    end

    def alternative_decision?(decision)
      kind = value(decision, :kind).to_s
      !kind.empty? && kind != "boolean"
    end

    def value(hash, key)
      return nil unless hash.respond_to?(:key?)
      return hash[key] if hash.key?(key)

      alternate = key.is_a?(Symbol) ? key.to_s : key.to_sym
      hash[alternate] if hash.key?(alternate)
    end
    private_class_method :value
  end
end
