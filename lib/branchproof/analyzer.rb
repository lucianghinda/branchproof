# frozen_string_literal: true

require "json"

module Branchproof
  # Performs the Boolean, occurrence-level masking analysis. It deliberately
  # accepts plain records so the core does not depend on Minitest or Runtime.
  class Analyzer
    CRITERION = "masking_occurrence_v1"

    def initialize(inventory:, evidence:, limits:)
      @inventory = inventory || {}
      @evidence = evidence || {}
      @limits = limits || {}
      @vectors = records(@evidence, :vectors)
      @constraint_states = Hash.new(0)
      @missing_cache = {}
      @invalid_diagnostics = []
      @analysis_invalid = false
      @diagnostic_keys = Set.new
    end

    def call
      decisions = records(@inventory, :decisions).map { analyze_decision(_1) }
      proven = decisions.sum { |decision| decision[:condition_results].count { |result| result[:status] == "PROVEN" } }
      eligible = decisions.sum { |decision| decision[:unsupported] ? 0 : decision[:conditions].length }
      {
        criterion_version: CRITERION,
        decisions: decisions,
        proven_count: proven,
        eligible_count: eligible,
        completeness: completeness(decisions),
        diagnostics: decisions.flat_map { |decision| decision[:diagnostics] } + @invalid_diagnostics
      }.freeze
    end

    def pair?(decision_id:, condition_index:, left:, right:)
      return false unless compatible_vectors?(left, right, decision_id)
      return false unless observed?(left, condition_index) && observed?(right, condition_index)
      return false if value(left, condition_index) == value(right, condition_index)
      return false if outcome(left) == outcome(right)

      masks = [left, right].map { effective_mask(_1, decision_id) }
      masks.all? { |mask| mask&.anybits?(1 << condition_index) }
    end

    def missing(decision_id:, condition_index:)
      cache_key = [decision_id, condition_index]
      return @missing_cache[cache_key] if @missing_cache.key?(cache_key)

      decision = records(@inventory, :decisions).find { id(_1, :id) == decision_id }
      return @missing_cache[cache_key] = nil unless decision

      support_status = id(decision, :support_status).to_s
      return @missing_cache[cache_key] = nil unless support_status.empty? || support_status.upcase == "SUPPORTED"

      relevant = @vectors.select { id(_1, :decision_id) == decision_id }
      valid = relevant.filter_map { valid_vector(_1, decision) }
      if valid.empty?
        return @missing_cache[cache_key] = {
          status: "NO_OBSERVATIONS", constraints: [], candidate_vectors: [],
          existing_vector_id: nil,
          feasibility_statement: "No completed structural observation exists."
        }
      end
      return @missing_cache[cache_key] = nil if first_pair(valid, condition_index, decision_id)

      existing = valid.find { |vector| effective_mask(vector, decision_id).anybits?(1 << condition_index) }
      signs = existing ? [!value(existing, condition_index)] : [true, false]
      candidates = signs.filter_map { counterpart(decision, condition_index, _1) }
      candidates.select! do |candidate|
        !existing || pair?(decision_id: decision_id, condition_index: condition_index, left: existing,
                           right: candidate[:vector])
      end
      limited = @constraint_states[id(decision, :id)] > constraint_limit
      if limited
        @analysis_invalid = true
        add_diagnostic("limit_reached", "error", nil, id(decision, :id))
      end
      @missing_cache[cache_key] = {
        status: if limited
                  "LIMIT_REACHED"
                else
                  (candidates.empty? ? "INFEASIBLE_IN_MODEL" : "CANDIDATE")
                end,
        constraints: candidates.flat_map { _1[:constraints] }.uniq,
        candidate_vectors: candidates.map { _1[:vector] },
        existing_vector_id: existing && id(existing, :id),
        feasibility_statement: feasibility_statement(candidates)
      }
    end

    private

    def analyze_decision(decision)
      decision_id = id(decision, :id)
      unless id(decision, :support_status).to_s.empty? || id(decision, :support_status).to_s.upcase == "SUPPORTED"
        return {
          decision_id: decision_id, effective_masks_by_vector: {}, condition_results: [], witness_buckets: {},
          conditions: [], unsupported: true,
          completeness: { observation: true, attribution: true, analysis: true },
          diagnostics: [diagnostic("unsupported_decision", "warning", decision_id, nil)]
        }
      end

      vectors = @vectors.filter_map { |vector| valid_vector(vector, decision) }
      masks = vectors.to_h { |vector| [id(vector, :id), effective_mask(vector, decision_id)] }
      buckets = {}
      conditions(decision).each do |condition|
        index = id(condition, :index)
        # These keys are serialized enum labels, not Boolean values.
        # rubocop:disable-next Lint/BooleanSymbol -- serialized enum labels
        buckets[index] = { true: [], false: [] }
        vectors.each do |vector|
          mask = masks[id(vector, :id)]
          next unless mask&.anybits?(1 << index)

          # rubocop:disable-next Lint/BooleanSymbol -- serialized enum labels
          buckets[index][value(vector, index) ? :true : :false] << id(vector, :id)
        end
        buckets[index].each_value(&:sort!)
      end
      results = conditions(decision).map do |condition|
        index = id(condition, :index)
        # rubocop:disable Lint/BooleanSymbol -- serialized enum labels
        true_ids = buckets[index][:true]
        false_ids = buckets[index][:false]
        # rubocop:enable Lint/BooleanSymbol
        pair = first_pair(vectors, index, decision_id)
        {
          condition_id: id(condition, :id),
          status: pair ? "PROVEN" : "NOT_PROVEN",
          canonical_pair: pair && [id(pair[0], :id), id(pair[1], :id)],
          constraint_result: pair ? nil : missing(decision_id: decision_id, condition_index: index),
          reason: if pair
                    nil
                  else
                    (true_ids.empty? || false_ids.empty? ? "missing_effective_sign" : "no_independent_pair")
                  end
        }
      end
      {
        decision_id: decision_id,
        effective_masks_by_vector: masks,
        condition_results: results,
        witness_buckets: buckets,
        edge_table: edge_table(decision[:tree]),
        conditions: conditions(decision),
        completeness: { observation: true, attribution: true, analysis: !@analysis_invalid },
        diagnostics: []
      }
    end

    def valid_vector(vector, decision)
      return nil unless id(vector, :decision_id) == id(decision, :id)

      decision_source = id(decision, :source_id)
      vector_source = id(vector, :source_id)
      if decision_source && vector_source && decision_source != vector_source
        @analysis_invalid = true
        add_diagnostic("incompatible_evidence", "error", id(vector, :id), id(decision, :id))
        add_diagnostic("invalid_vector", "error", id(vector, :id), id(decision, :id))
        return nil
      end

      status = id(vector, :status)
      if status && status.to_s != "completed"
        @analysis_invalid = true
        add_diagnostic("incomplete_vector", "error", id(vector, :id))
        return nil
      end
      unless evidence_compatible?(vector)
        @analysis_invalid = true
        add_diagnostic("incompatible_evidence", "error", id(vector, :id))
        return nil
      end
      unless outcome(vector).is_a?(true.class) || outcome(vector).is_a?(false.class)
        @analysis_invalid = true
        add_diagnostic("invalid_vector", "error", id(vector, :id))
        return nil
      end

      effective_mask(vector, id(decision, :id), decision[:tree])
      vector
    rescue ArgumentError
      @analysis_invalid = true
      add_diagnostic("invalid_vector", "error", id(vector, :id))
      nil
    end

    def effective_mask(vector, decision_id, tree = nil)
      decision = records(@inventory, :decisions).find { id(_1, :id) == decision_id } unless tree
      tree ||= decision && decision[:tree]
      raise ArgumentError, "unknown decision" unless tree

      values = values_for(vector)
      index = 0
      result, mask, consumed = replay(tree, values, index)
      unless consumed == values.compact.length && result == outcome(vector)
        raise ArgumentError,
              "invalid structural trace"
      end

      mask
    end

    def replay(node, values, offset)
      type = id(node, :type).to_sym
      if type == :atom
        index = id(node, :index)
        value = values[index]
        raise ArgumentError, "missing atom" if value.nil?

        return [value, 1 << index, offset + 1]
      end
      left_result, left_mask, consumed = replay(node.fetch(:left), values, offset)
      return [left_result, left_mask, consumed] if (type == :and && !left_result) || (type == :or && left_result)

      right_result, right_mask, consumed = replay(node.fetch(:right), values, consumed)
      if (type == :and && !right_result) || (type == :or && right_result)
        [right_result, right_mask, consumed]
      else
        [right_result, left_mask | right_mask, consumed]
      end
    end

    def first_pair(vectors, index, decision_id)
      observed_vectors = vectors.select do |vector|
        observed?(vector, index) && effective_mask(vector, decision_id).anybits?(1 << index)
      end
      observed_vectors.sort_by! { |vector| id(vector, :id).to_s }
      grouped = observed_vectors.group_by do |vector|
        # rubocop:disable-next Lint/BooleanSymbol -- serialized enum labels
        value(vector, index) ? :true : :false
      end
      # rubocop:disable Lint/BooleanSymbol -- serialized enum labels
      false_by_outcome = grouped.fetch(:false, []).group_by { |vector| outcome(vector) }
      true_by_outcome = grouped.fetch(:true, []).group_by { |vector| outcome(vector) }
      # rubocop:enable Lint/BooleanSymbol
      false_by_outcome.each do |left_outcome, left_vectors|
        right_vectors = true_by_outcome[!left_outcome]
        next if right_vectors.nil?

        left = left_vectors.first
        right = right_vectors.first
        return [left, right] if pair?(decision_id: decision_id, condition_index: index, left: left, right: right)
      end
      nil
    end

    def compatible_vectors?(left, right, decision_id)
      id(left, :decision_id) == decision_id && id(right, :decision_id) == decision_id &&
        source_identity(left) == source_identity(right) && complete?(left) && complete?(right)
    end

    def counterpart(decision, target, target_value)
      decision_id = id(decision, :id)
      @constraint_states[decision_id] += 1
      return nil if @constraint_states[decision_id] > constraint_limit

      target_condition = conditions(decision).find { |condition| id(condition, :index) == target }
      return nil if target_condition && !id(target_condition,
                                            :literal_truth).nil? && id(target_condition, :literal_truth) != target_value

      return nil unless contains?(decision[:tree], target)

      constraints = [{ condition_index: target, value: target_value }]
      @constraint_decision_conditions = conditions(decision)
      @constraint_current_decision = decision_id
      return nil unless impose_path(decision[:tree], target, target_value, constraints)

      values = Array.new(conditions(decision).length, false)
      constraints.each { |constraint| values[constraint[:condition_index]] = constraint[:value] }
      values[target] = target_value
      outcome, observed = evaluate_with_trace(decision[:tree], values)
      sparse = Array.new(values.length)
      observed.each { |index, value| sparse[index] = value }
      vector = { decision_id: id(decision, :id), source_id: id(decision, :source_id), status: "completed",
                 values: sparse, outcome: outcome, id: "candidate-#{target}-#{target_value}" }
      constraints.each do |constraint|
        condition = conditions(decision).find { |item| id(item, :index) == constraint[:condition_index] }
        constraint[:condition_id] = id(condition, :id)
        constraint[:required] = constraint[:value]
      end
      { constraints: constraints, vector: vector }
    end

    def feasibility_statement(candidates)
      return "Boolean requirement; application-level feasibility unknown" unless candidates.empty?

      "Boolean requirement is not satisfiable in the model; application-level feasibility unknown"
    end

    def constraint_limit
      value = id(@limits, :constraint_search_states)
      value&.to_i&.positive? ? value.to_i : 10_000
    end

    def edge_table(node)
      graph = build_graph(node)
      graph[:edges]
    end

    # rubocop:disable Lint/BooleanSymbol -- serialized enum labels
    def build_graph(node, true_destination = :true, false_destination = :false)
      # rubocop:enable Lint/BooleanSymbol
      if id(node, :type).to_sym == :atom
        index = id(node, :index)
        entry = "atom#{index}"
        edges = [{ from: entry, truth: true, destination: true_destination, clear_mask: 0, index: index },
                 { from: entry, truth: false, destination: false_destination, clear_mask: 0, index: index }]
        return { entry: entry, true_exits: [edges[0]], false_exits: [edges[1]], all_bits: 1 << index, edges: edges }
      end
      type = id(node, :type).to_sym
      right = build_graph(node[:right], true_destination, false_destination)
      if type == :and
        left = build_graph(node[:left], right[:entry], false_destination)
        right[:false_exits].each { |edge| edge[:clear_mask] |= left[:all_bits] }
        { entry: left[:entry], true_exits: right[:true_exits], false_exits: left[:false_exits] + right[:false_exits],
          all_bits: left[:all_bits] | right[:all_bits], edges: left[:edges] + right[:edges] }
      else
        left = build_graph(node[:left], true_destination, right[:entry])
        right[:true_exits].each { |edge| edge[:clear_mask] |= left[:all_bits] }
        { entry: left[:entry], true_exits: left[:true_exits] + right[:true_exits], false_exits: right[:false_exits],
          all_bits: left[:all_bits] | right[:all_bits], edges: left[:edges] + right[:edges] }
      end
    end

    def impose_path(node, target, target_value, constraints)
      return true if id(node, :type).to_sym == :atom && id(node, :index) == target

      left = node[:left]
      right = node[:right]
      if contains?(left, target)
        neutral = id(node, :type).to_sym == :and
        impose_subtree(right, neutral, constraints) && impose_path(left, target, target_value, constraints)
      elsif contains?(right, target)
        impose_subtree(left, id(node, :type).to_sym == :and, constraints) &&
          impose_path(right, target, target_value, constraints)
      else
        false
      end
    end

    def impose_subtree(node, desired, constraints)
      @constraint_states[@constraint_current_decision] += 1
      return false if @constraint_states[@constraint_current_decision] > constraint_limit

      if id(node, :type).to_sym == :atom
        condition = @constraint_decision_conditions.find { |item| id(item, :index) == id(node, :index) }
        return false if condition && !id(condition, :literal_truth).nil? && id(condition, :literal_truth) != desired

        constraints << { condition_index: id(node, :index), value: desired }
        true
      elsif desired == (id(node, :type).to_sym == :and)
        impose_subtree(node[:left], desired, constraints) && impose_subtree(node[:right], desired, constraints)
      else
        impose_subtree(node[:left], desired, constraints) || impose_subtree(node[:right], desired, constraints)
      end
    end

    def evaluate(node, values)
      return values[id(node, :index)] if id(node, :type).to_sym == :atom

      left = evaluate(node[:left], values)
      return left if id(node, :type).to_sym == :and && !left
      return left if id(node, :type).to_sym == :or && left

      evaluate(node[:right], values)
    end

    def evaluate_with_trace(node, values, trace = [])
      if id(node, :type).to_sym == :atom
        value = !values[id(node, :index)].nil? && values[id(node, :index)] != false
        trace << [id(node, :index), value]
        return [value, trace]
      end
      left, = evaluate_with_trace(node[:left], values, trace)
      return [left, trace] if id(node, :type).to_sym == :and && !left
      return [left, trace] if id(node, :type).to_sym == :or && left

      evaluate_with_trace(node[:right], values, trace)
    end

    def contains?(node, target)
      if id(node,
            :type).to_sym == :atom
        id(node,
           :index) == target
      else
        contains?(node[:left],
                  target) || contains?(node[:right], target)
      end
    end

    def values_for(vector)
      raw = vector[:values] || vector["values"]
      raise ArgumentError, "observation must contain booleans or nil" unless raw.is_a?(Array)
      unless raw.all? { |value| value.nil? || value == true || value == false }
        raise ArgumentError, "observation must contain booleans or nil"
      end

      raw
    end

    def outcome(vector) = vector[:outcome].nil? ? vector["outcome"] : vector[:outcome]
    def value(vector, index) = values_for(vector)[index]
    def observed?(vector, index) = !value(vector, index).nil?

    def complete?(vector)
      status = vector[:status] || vector["status"]
      status.nil? || status.to_s == "completed"
    end

    def source_identity(vector) = vector[:source_id] || vector["source_id"]

    def id(record, key) = record[key].nil? ? record[key.to_s] : record[key]

    def records(record, key) = Array(id(record, key))
    def conditions(decision) = records(decision, :conditions)

    def evidence_compatible?(_vector)
      schema = id(@evidence, :schema_version)
      criterion = id(@evidence, :criterion_version)
      (schema.nil? || schema.to_s.split(".").first == "1") &&
        (criterion.nil? || criterion.to_s == CRITERION)
    end

    def diagnostic(code, severity, decision_id, vector_id)
      { code: code, severity: severity, message: code.to_s, source_id: nil,
        decision_id: decision_id, execution_id: nil, test_id: nil,
        details: { vector_id: vector_id } }
    end

    def add_diagnostic(code, severity, vector_id, decision_id = nil)
      key = [code, vector_id, decision_id]
      return if @diagnostic_keys.include?(key)

      @diagnostic_keys << key
      @invalid_diagnostics << diagnostic(code, severity, decision_id, vector_id)
    end

    def completeness(decisions)
      evidence_completeness = id(@evidence, :completeness) || {}
      nested_analysis = evidence_completeness.fetch(:analysis, evidence_completeness.fetch("analysis", true))
      { observation: evidence_completeness.fetch(:observation, evidence_completeness.fetch("observation", true)),
        attribution: evidence_completeness.fetch(:attribution, evidence_completeness.fetch("attribution", true)),
        analysis: !@analysis_invalid && nested_analysis && decisions.all? do |decision|
          decision[:completeness][:analysis]
        end &&
          id(@evidence, :analysis) != false }
    end
  end
end
