# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/ParameterLists

module Branchproof
  # Evaluates configured coverage thresholds against the aggregate Analyzer
  # coverage counts without relying on rounded percentage fields.
  class CoveragePolicy
    CRITERIA = {
      "decision" => { numerator: "covered_decisions", denominator: "supported_decisions" },
      "condition" => { numerator: "covered_values", denominator: "required_values" },
      "condition_decision" => { numerator: "covered_decisions", denominator: "supported_decisions" },
      "mcdc" => { numerator: "proven_conditions", denominator: "supported_conditions" },
      "decision_table" => { numerator: "covered_rules", denominator: "required_rules" }
    }.freeze
    COMPLETENESS_FIELDS = %w[observation attribution analysis].freeze

    class << self
      def normalize(minimum)
        raise ArgumentError, "minimum must be a hash" unless minimum.is_a?(Hash)

        minimum.each_with_object({}) do |(key, threshold), normalized|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise ArgumentError, "unknown coverage criterion: #{key.inspect}"
          end

          criterion = key.to_s
          raise ArgumentError, "unknown coverage criterion: #{criterion}" unless CRITERIA.key?(criterion)
          raise ArgumentError, "duplicate coverage criterion: #{criterion}" if normalized.key?(criterion)

          validate_threshold!(criterion, threshold)
          normalized[criterion] = threshold
        end
      end

      private

      def validate_threshold!(criterion, threshold)
        valid_type = threshold.is_a?(Integer) || threshold.is_a?(Float)
        valid_float = !threshold.is_a?(Float) || threshold.finite?
        unless valid_type && valid_float
          raise ArgumentError, "coverage minimum for #{criterion} must be a finite number"
        end
        return if (0..100).cover?(threshold)

        raise ArgumentError, "coverage minimum for #{criterion} must be between 0 and 100"
      end
    end

    def initialize(minimum:)
      @minimum = self.class.normalize(minimum)
    end

    def call(document:)
      return { minimum: @minimum.dup, status: "passed", gates: [] } if @minimum.empty?

      global_reason = availability_reason(document)
      gates = @minimum.map do |criterion, threshold|
        evaluate_gate(criterion, threshold, document, global_reason)
      end

      status = if gates.any? { |gate| gate[:status] == "unavailable" }
                 "unavailable"
               elsif gates.any? { |gate| gate[:status] == "failed" }
                 "failed"
               else
                 "passed"
               end

      { minimum: @minimum.dup, status: status, gates: gates }
    end

    private

    def availability_reason(document)
      return "document_unavailable" unless document.is_a?(Hash)

      baseline = value(document, :baseline)
      baseline_passed = baseline.is_a?(Hash) && value(baseline, :status).to_s.upcase == "PASSED"
      return "baseline_unavailable" unless baseline_passed && value(baseline, :finalized) == true
      return "incomplete_document" unless complete?(value(document, :completeness))

      observations = value(document, :observations) || value(document, :evidence)
      return "incomplete_observations" if incomplete_section?(observations)

      analysis = value(document, :analysis)
      return "incomplete_analysis" if incomplete_section?(analysis)

      nil
    end

    def complete?(completeness)
      return false unless completeness.is_a?(Hash)

      COMPLETENESS_FIELDS.all? { |field| value(completeness, field) == true }
    end

    def incomplete_section?(section)
      section.is_a?(Hash) && key_present?(section, :completeness) && !complete?(value(section, :completeness))
    end

    def evaluate_gate(criterion, threshold, document, global_reason)
      return gate(criterion, threshold, nil, nil, "unavailable", global_reason) if global_reason

      coverage = value(value(document, :analysis), :coverage)
      row = value(coverage, criterion)
      return gate(criterion, threshold, nil, nil, "unavailable", "missing_coverage_count") unless row.is_a?(Hash)

      mapping = CRITERIA.fetch(criterion)
      numerator = value(row, mapping.fetch(:numerator))
      denominator = value(row, mapping.fetch(:denominator))

      if criterion == "decision_table"
        not_calculated = value(row, :not_calculated_decisions)
        unless not_calculated.nil?
          unless valid_count?(not_calculated)
            return gate(criterion, threshold, numerator, denominator, "unavailable", "invalid_coverage_count")
          end
          if not_calculated.positive?
            return gate(criterion, threshold, numerator, denominator, "unavailable", "decision_table_not_calculated")
          end
        end
      end

      if numerator.nil? || denominator.nil?
        return unavailable_gate(criterion, threshold, numerator, denominator, "missing_coverage_count")
      end
      unless valid_count?(numerator) && valid_count?(denominator)
        return unavailable_gate(criterion, threshold, numerator, denominator, "invalid_coverage_count")
      end
      return unavailable_gate(criterion, threshold, numerator, denominator, "zero_denominator") if denominator.zero?
      if numerator > denominator
        return unavailable_gate(criterion, threshold, numerator, denominator, "invalid_coverage_count")
      end

      status = numerator * 100 >= denominator * Rational(threshold.to_s) ? "passed" : "failed"
      gate(criterion, threshold, numerator, denominator, status, nil)
    end

    def valid_count?(value)
      value.is_a?(Integer) && value >= 0
    end

    def gate(criterion, threshold, numerator, denominator, status, reason)
      { criterion: criterion, numerator: numerator, denominator: denominator, minimum: threshold,
        status: status, reason: reason }
    end

    def unavailable_gate(criterion, threshold, numerator, denominator, reason)
      gate(criterion, threshold, numerator, denominator, "unavailable", reason)
    end

    def value(hash, key)
      return nil unless hash.respond_to?(:key?)
      return hash[key] if hash.key?(key)

      alternate = key.is_a?(Symbol) ? key.to_s : key.to_sym
      return hash[alternate] if hash.key?(alternate)

      nil
    end

    def key_present?(hash, key)
      hash.key?(key) || hash.key?(key.to_s) || hash.key?(key.to_sym)
    end
  end
end

# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/ParameterLists
