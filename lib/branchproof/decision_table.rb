# frozen_string_literal: true

require_relative "records"
require_relative "constraints"
require_relative "limits"

module Branchproof
  # Derives the executable logical rules of a supported Boolean decision and
  # overlays the runtime evidence that the existing Branchproof run captured.
  #
  # Rules come from the Boolean tree itself rather than from an exhaustive
  # Cartesian expansion, so Ruby's short-circuit semantics are preserved: a
  # condition the interpreter would skip becomes an explicit +dont_care+ value
  # instead of two separate rules.
  #
  # Nothing here executes application code, and no additional test run is
  # required: overlay consumes the vectors already recorded for the decision.
  module DecisionTable
    SCHEMA_VERSION = 1
    CONSTRAINT_ANALYSIS_VERSION = Constraints::VERSION
    TRUE_VALUE = "true"
    FALSE_VALUE = "false"
    DONT_CARE = "dont_care"
    VALUE_LABELS = { TRUE_VALUE => "T", FALSE_VALUE => "F", DONT_CARE => "-" }.freeze
    CONDITION_VALUES = [TRUE_VALUE, FALSE_VALUE, DONT_CARE].freeze
    REACHABILITY_STATUSES = %w[observed unknown statically_impossible].freeze
    COVERAGE_STATUSES = %w[covered missing excluded].freeze
    TABLE_STATUSES = %w[calculated not_calculated].freeze
    COVERAGE_SUMMARY_STATUSES = %w[covered partial unexecuted unsupported not_calculated].freeze
    NOT_CALCULATED_REASONS = %w[
      unsupported_decision decision_table_unavailable
      decision_table_condition_limit_exceeded decision_table_rule_limit_exceeded
    ].freeze
    DEFAULT_MAX_CONDITIONS = Limits::DEFAULTS[:max_conditions_for_decision_table]
    DEFAULT_MAX_RULES = Limits::DEFAULTS[:decision_table_rules_per_decision]

    module_function

    # Builds the reduced, runtime-overlaid table for one Boolean decision.
    def build(decision:, vectors: [], limits: {}, reachability: true)
      raise ArgumentError, "reachability must be a Boolean" unless [true, false].include?(reachability)

      decision_id = fetch(decision, :id).to_s
      reason = unavailable_reason(decision, limits)
      return not_calculated(decision_id, reason) if reason

      max_rules = limit(limits, :decision_table_rules_per_decision, DEFAULT_MAX_RULES)
      paths = enumerate(fetch(decision, :tree), false, max_rules + 1)
      return not_calculated(decision_id, "decision_table_rule_limit_exceeded") if paths.nil? || paths.length > max_rules

      conditions = Array(fetch(decision, :conditions))
      prepared_constraints = conditions.map do |condition|
        raw = fetch(condition, :constraint)
        raw = Constraints.symbolize(raw)
        fetch(condition, :constraint_safe) == true && Constraints.usable?(raw) ? raw : nil
      end
      rules = paths.each_with_index.map do |path, index|
        rule(decision_id, conditions, path, index, reachability: reachability,
                                                   prepared_constraints: prepared_constraints)
      end
      overlay(decision_id: decision_id, rules: rules, vectors: Array(vectors), reachability: reachability,
              indexed: unique_atom_indices?(fetch(decision, :tree)))
    end

    # Names why a decision carries no Boolean table, or nil when it carries one.
    def unavailable_reason(decision, limits)
      support = fetch(decision, :support_status).to_s
      return "unsupported_decision" unless support.empty? || support.casecmp("supported").zero?

      tree = fetch(decision, :tree)
      return "decision_table_unavailable" if tree.nil?

      conditions = Array(fetch(decision, :conditions)).length
      return "decision_table_condition_limit_exceeded" if conditions >
                                                          limit(limits, :max_conditions_for_decision_table,
                                                                DEFAULT_MAX_CONDITIONS)
      return "decision_table_unavailable" unless representable?(tree, conditions)

      nil
    end

    # Only AND, OR, NOT, and atoms within the decision's own condition range are
    # representable; anything else leaves the table uncalculated rather than
    # producing a table that does not describe the decision.
    def representable?(node, condition_count)
      case fetch(node, :type).to_s
      when "atom" then fetch(node, :index).is_a?(Integer) && (0...condition_count).cover?(fetch(node, :index))
      when "not" then representable?(fetch(node, :child), condition_count)
      when "and", "or"
        representable?(fetch(node, :left), condition_count) &&
          representable?(fetch(node, :right), condition_count)
      else false
      end
    end

    def unique_atom_indices?(node, seen = {})
      case fetch(node, :type).to_s
      when "atom"
        index = fetch(node, :index)
        return false if seen.key?(index)

        seen[index] = true
        true
      when "not"
        unique_atom_indices?(fetch(node, :child), seen)
      when "and", "or"
        unique_atom_indices?(fetch(node, :left), seen) && unique_atom_indices?(fetch(node, :right), seen)
      else false
      end
    end

    # Enumerates every short-circuit evaluation path of the Boolean tree.
    #
    # +prefer+ orders the paths deterministically: a conjunction lists its
    # short-circuiting false path first, a disjunction its true path first, and
    # a negation inverts the preference it inherits. Returns nil once the path
    # count would exceed +budget+.
    def enumerate(node, prefer, budget)
      type = fetch(node, :type).to_s
      case type
      when "atom"
        index = fetch(node, :index).to_i
        (prefer ? [true, false] : [false, true]).map { |value| { assignments: { index => value }, value: value } }
      when "not"
        paths = enumerate(fetch(node, :child), !prefer, budget)
        paths&.map { |path| { assignments: path[:assignments], value: !path[:value] } }
      when "and", "or"
        combine(node, type, budget)
      end
    end

    def combine(node, type, budget)
      short_circuit = type != "and"
      left = enumerate(fetch(node, :left), short_circuit, budget)
      return nil unless left

      right = nil
      paths = []
      left.each do |path|
        if path[:value] == short_circuit
          paths << path
          next
        end
        right ||= enumerate(fetch(node, :right), short_circuit, budget)
        return nil unless right

        right.each do |tail|
          paths << { assignments: path[:assignments].merge(tail[:assignments]), value: tail[:value] }
        end
        return nil if paths.length > budget
      end
      paths.length > budget ? nil : paths
    end

    # rubocop:disable-next Metrics/ParameterLists
    def rule(decision_id, conditions, path, index, reachability: true, prepared_constraints: nil)
      values = Array.new(conditions.length, DONT_CARE)
      path[:assignments].each do |condition_index, value|
        values[condition_index] = value ? TRUE_VALUE : FALSE_VALUE if condition_index < values.length
      end
      outcome = path[:value] ? true : false
      reachability_state, reason = if reachability
                                     static_reachability(conditions, values, prepared_constraints: prepared_constraints)
                                   else
                                     ["unknown", nil]
                                   end
      { id: rule_id(decision_id, values, outcome), label: "R#{index + 1}", index: index,
        conditions: values, outcome: outcome, reachability: reachability_state, reachability_reason: reason }
    end

    # Rule identity depends only on the decision, the normalized condition
    # vector, the expected outcome, and the table schema version. It never
    # depends on a test name, a runtime observation, or the Minitest seed.
    def rule_id(decision_id, values, outcome)
      Records.id(schema_version: SCHEMA_VERSION, decision_id: decision_id.to_s,
                 conditions: values, outcome: outcome)
    end

    # Conservative static reachability: prove impossibility, or answer unknown.
    def static_reachability(conditions, values, prepared_constraints: nil)
      solver = Constraints::Solver.new
      values.each_with_index do |value, index|
        next if value == DONT_CARE

        condition = conditions[index] || {}
        truth = value == TRUE_VALUE
        literal = fetch(condition, :literal_truth)
        return %w[statically_impossible boolean_literal_conflict] if !literal.nil? && literal != truth

        next unless fetch(condition, :constraint_safe) == true

        prepared = prepared_constraints && prepared_constraints[index]
        reason = if prepared
                   solver.add_prepared(prepared, truth)
                 else
                   solver.add(fetch(condition, :constraint), truth)
                 end
        return ["statically_impossible", reason] if reason
      end
      ["unknown", nil]
    end

    def overlay(decision_id:, rules:, vectors:, reachability: true, indexed: false)
      diagnostics = []
      matches = indexed ? classify_vectors(rules, vectors) : generic_matches(rules, vectors)
      overlaid = rules.each_with_index.map do |item, index|
        overlay_rule_matches(decision_id, item, matches[index], diagnostics)
      end
      summary(decision_id: decision_id, rules: overlaid, diagnostics: diagnostics,
              reachability_analyzed: reachability)
    end

    # Generated traces have nil in every skipped condition position. Their
    # normalized vector is therefore an exact table key and can be classified
    # without scanning every rule. Malformed or hand-built observations retain
    # the historical matcher as a bounded compatibility fallback.
    def classify_vectors(rules, vectors)
      condition_count = rules.first ? Array(rules.first[:conditions]).length : 0
      by_signature = {}
      rules.each_with_index do |item, position|
        (by_signature[signature(item[:conditions], item[:outcome])] ||= []) << position
      end
      matches = Array.new(rules.length) { [] }
      vectors.each do |vector|
        positions = fast_match_positions(vector, by_signature, condition_count)
        if positions&.length == 1
          matches[positions.first] << vector
        else
          rules.each_with_index do |item, position|
            matches[position] << vector if matches?(item, vector)
          end
        end
      end
      matches
    end

    def generic_matches(rules, vectors)
      matches = Array.new(rules.length) { [] }
      rules.each_with_index do |rule, position|
        vectors.each { |vector| matches[position] << vector if matches?(rule, vector) }
      end
      matches
    end

    def signature(values, outcome)
      [outcome ? true : false, Array(values).map { |value| value == DONT_CARE ? nil : value == TRUE_VALUE }]
    end

    def fast_match_positions(vector, by_signature, condition_count)
      values = Array(fetch(vector, :values))
      valid_values = values.all? { |value| value.nil? || value == true || value == false }
      return nil unless values.length >= condition_count && valid_values

      normalized = values.first(condition_count).map do |value|
        if value.nil?
          DONT_CARE
        elsif value
          TRUE_VALUE
        else
          FALSE_VALUE
        end
      end
      by_signature[signature(normalized, fetch(vector, :outcome))]
    end

    # Public compatibility wrapper: callers historically passed all vectors,
    # so retain matcher filtering for direct calls.
    def overlay_rule(decision_id, rule, vectors, diagnostics)
      matched = Array(vectors).select { |vector| matches?(rule, vector) }
      overlay_rule_matches(decision_id, rule, matched, diagnostics)
    end

    def overlay_rule_matches(decision_id, rule, matched, diagnostics)
      observed = !matched.empty?
      impossible = rule[:reachability] == "statically_impossible"
      withdrawn = observed && impossible
      if withdrawn
        diagnostics << Records.diagnostic(
          code: "constraint_model_conflict", severity: "warning",
          message: "runtime evidence matched a statically impossible decision-table rule; " \
                   "the impossibility claim is withdrawn",
          decision_id: decision_id,
          details: { rule_id: rule[:id], rule_label: rule[:label],
                     reachability_reason: rule[:reachability_reason].to_s }
        )
      end
      rule.merge(
        coverage: if observed
                    "covered"
                  else
                    (impossible ? "excluded" : "missing")
                  end,
        reachability: observed ? "observed" : rule[:reachability],
        reachability_reason: observed ? nil : rule[:reachability_reason],
        impossible_withdrawn: withdrawn,
        withdrawn_reason: withdrawn ? rule[:reachability_reason] : nil,
        tests: matched.flat_map { |vector| Array(fetch(vector, :test_ids)).map(&:to_s) }.uniq.sort,
        vector_ids: matched.map { |vector| fetch(vector, :id).to_s }.uniq.sort,
        unattributed_count: matched.sum { |vector| fetch(vector, :unattributed_count).to_i }
      )
    end

    # A runtime observation matches a rule when every required condition value
    # matches and the decision outcome matches. Conditions Ruby skipped may only
    # line up with don't-care positions.
    def matches?(rule, vector)
      return false unless (fetch(vector, :outcome) ? true : false) == rule[:outcome]

      values = Array(fetch(vector, :values))
      rule[:conditions].each_with_index.all? do |required, index|
        next true if required == DONT_CARE

        values[index] == (required == TRUE_VALUE)
      end
    end

    def summary(decision_id:, rules:, diagnostics:, reachability_analyzed: true)
      generated = rules.length
      impossible = rules.count { |rule| rule[:coverage] == "excluded" }
      required = generated - impossible
      covered = rules.count { |rule| rule[:coverage] == "covered" }
      { status: "calculated", reason: nil, decision_id: decision_id,
        schema_version: SCHEMA_VERSION, constraint_analysis_version: CONSTRAINT_ANALYSIS_VERSION,
        rules: rules, generated_rules: generated, impossible_rules: impossible,
        required_rules: required, covered_rules: covered, missing_rules: required - covered,
        coverage_status: coverage_status(covered, required, generated),
        percentage: percentage(covered, required), reachability_analyzed: reachability_analyzed,
        diagnostics: diagnostics }
    end

    def coverage_status(covered, required, generated)
      return "unexecuted" if generated.zero?
      return "covered" if required.zero? || covered == required
      return "unexecuted" if covered.zero?

      "partial"
    end

    def not_calculated(decision_id, reason)
      { status: "not_calculated", reason: reason, decision_id: decision_id,
        schema_version: SCHEMA_VERSION, constraint_analysis_version: CONSTRAINT_ANALYSIS_VERSION,
        rules: [], generated_rules: 0, impossible_rules: 0, required_rules: 0, covered_rules: 0,
        missing_rules: 0,
        coverage_status: reason == "unsupported_decision" ? "unsupported" : "not_calculated",
        percentage: nil, reachability_analyzed: false, diagnostics: [] }
    end

    # The per-decision row the coverage ladder renders.
    def coverage_entry(table)
      { status: table[:coverage_status], table_status: table[:status], reason: table[:reason],
        covered_rules: table[:covered_rules], required_rules: table[:required_rules],
        generated_rules: table[:generated_rules], impossible_rules: table[:impossible_rules],
        missing_rules: table[:missing_rules], percentage: table[:percentage],
        reachability_analyzed: table[:reachability_analyzed] }
    end

    def unsupported_coverage_entry
      coverage_entry(not_calculated(nil, "unsupported_decision"))
    end

    def percentage(covered, required)
      required.zero? ? nil : (covered.to_f / required * 100).round(2)
    end

    def limit(limits, key, fallback)
      value = fetch(limits, key)
      value.is_a?(Integer) && value.positive? ? value : fallback
    end

    def fetch(record, key)
      return nil unless record.respond_to?(:key?)
      return record[key] if record.key?(key)

      record[key.to_s]
    end
  end
end
