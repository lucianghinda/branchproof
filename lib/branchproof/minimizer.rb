# frozen_string_literal: true

# rubocop:disable-next Lint/RedundantRequireStatement -- supports standalone core entry
require "set"

module Branchproof
  # Computes minimum vector or test covers for proven obligations.
  class Minimizer
    def initialize(analysis:, evidence:, limits:)
      @analysis = analysis || {}
      @evidence = evidence || {}
      @limits = limits || {}
    end

    def call(objective:, decision_ids:)
      raise ArgumentError, "objective must be :vectors or :tests" unless %i[vectors tests].include?(objective)

      scope = Array(decision_ids).map(&:to_s).sort
      if objective == :vectors && scope.length != 1
        raise ArgumentError,
              "vector objective requires exactly one decision"
      end

      target = target_obligations(scope)
      return result(objective, scope, target, [], "EXACT_MINIMUM", nil, 0, []) if target.empty?

      candidates = objective == :tests ? test_candidates(scope) : vector_candidates(scope)
      candidates = candidates.transform_values { |signs| signs & target }
      union = candidates.values.reduce(Set.new) { |set, signs| set | signs }
      missing = target - union
      unless missing.empty?
        return result(objective, scope, target, [], "NOT_AVAILABLE", nil, 0,
                      ["missing ownership: #{format_obligations(missing)}"])
      end

      candidate_cap = integer_limit(:exact_candidates, 32)
      exact_candidate_set = candidates.keys.length <= candidate_cap
      unless exact_candidate_set
        selected = greedy(candidates.keys.sort, candidates, target)
        covered = selected.reduce(Set.new) { |set, candidate| set | candidates.fetch(candidate, Set.new) }
        status = covered >= target ? "BEST_FOUND" : "NOT_AVAILABLE"
        reasons = if status == "BEST_FOUND"
                    ["candidate count exceeds exact search limit"]
                  else
                    ["candidate union is incomplete"]
                  end
        return result(objective, scope, target, selected, status, nil, 0, reasons, candidates)
      end
      selected, exact, lower, visited = search(candidates, target)
      exact &&= exact_candidate_set
      covered = selected.reduce(Set.new) { |set, candidate| set | candidates.fetch(candidate, Set.new) }
      status = exact && covered >= target ? "EXACT_MINIMUM" : "BEST_FOUND"
      result(objective, scope, target, selected, status, lower, visited,
             status == "EXACT_MINIMUM" ? [] : ["exact search budget exhausted"], candidates)
    end

    private

    def target_obligations(scope)
      records(@analysis, :decisions).select { scope.include?(id(_1, :decision_id).to_s) }.flat_map do |decision|
        records(decision, :condition_results).filter_map do |condition|
          next unless id(condition, :status).to_s == "PROVEN"

          condition_id = id(condition, :condition_id).to_s
          index = records(decision, :conditions).find { id(_1, :id).to_s == condition_id }
          idx = index && id(index, :index)
          [true, false].map { |sign| [id(decision, :decision_id).to_s, idx, sign] }
        end
      end.flatten(1).to_set
    end

    def vector_candidates(scope)
      selected_decisions = records(@analysis, :decisions).select do |decision|
        scope.include?(id(decision, :decision_id).to_s)
      end
      masks = selected_decisions.to_h do |decision|
        [id(decision, :decision_id).to_s, id(decision, :effective_masks_by_vector) || {}]
      end
      records(@evidence, :vectors).each_with_object({}) do |vector, result|
        decision_id = id(vector, :decision_id).to_s
        next unless masks.key?(decision_id)

        mask = masks[decision_id][id(vector, :id)] || masks[decision_id][id(vector, :id).to_s]
        next unless mask

        indexes = mask.to_i.digits(2).each_index.select { |index| mask.to_i[index] == 1 }
        signs = indexes.flat_map do |index|
          [[decision_id, index, true], [decision_id, index, false]].select do |obligation|
            value(vector, index) == obligation[2]
          end
        end.to_set
        result[id(vector, :id).to_s] = signs
      end
    end

    def test_candidates(scope)
      vectors = vector_candidates(scope)
      result = Hash.new { |hash, key| hash[key] = Set.new }
      records(@evidence, :vectors).each do |vector|
        test_ids = records(vector, :test_ids)
        next if test_ids.empty?

        signs = vectors[id(vector, :id).to_s]
        next unless signs

        test_ids.each { |test_id| result[test_id.to_s] |= signs }
      end
      result
    end

    def search(candidates, target)
      ids = candidates.keys.sort
      best = greedy(ids, candidates, target)
      nodes = 0
      limit = integer_limit(:exact_search_nodes, 100_000)
      exact = true
      visit = lambda do |position, chosen, covered|
        if nodes >= limit
          exact = false
          return
        end
        nodes += 1
        if covered >= target
          candidate = chosen.sort
          if candidate.length < best.length || (candidate.length == best.length && (candidate <=> best) == -1)
            best = candidate
          end
          return
        end
        return if position >= ids.length || chosen.length >= best.length

        gain = candidates[ids[position]] - covered
        visit.call(position + 1, chosen, covered)
        visit.call(position + 1, chosen + [ids[position]], covered | gain) unless gain.empty?
      end
      visit.call(0, [], Set.new)
      greatest_gain = candidates.values.map(&:length).max.to_i
      lower_bound = greatest_gain.zero? ? nil : ((target.length + greatest_gain - 1) / greatest_gain)
      [best, exact, lower_bound, nodes]
    end

    def greedy(ids, candidates, target)
      positions = ids.each_with_index.to_h
      chosen = []
      chosen_set = Set.new
      covered = Set.new
      until covered >= target
        available = ids.reject { |candidate| chosen_set.include?(candidate) }
        id = available.max_by { |candidate| [(candidates[candidate] - covered).length, -positions[candidate]] }
        break unless id
        break if (candidates[id] - covered).empty?

        chosen << id
        chosen_set << id
        covered |= candidates[id]
      end
      chosen.sort.reverse_each do |candidate|
        trial = chosen - [candidate]
        trial_covered = trial.reduce(Set.new) { |set, item| set | candidates[item] }
        chosen = trial if trial_covered >= target
      end
      chosen.sort
    end

    # For each target obligation, how many candidates cover it. An obligation
    # covered by exactly one candidate makes that candidate irreplaceable.
    def coverage_counts(candidates)
      candidates.each_value.with_object(Hash.new(0)) do |signs, counts|
        signs.each { |obligation| counts[obligation] += 1 }
      end
    end

    def result(objective, scope, target, selected, status, lower, visited, reasons, candidates = {})
      counts = coverage_counts(candidates)
      necessary = candidates.select { |_, signs| signs.any? { |obligation| counts[obligation] == 1 } }.keys
      interchangeable = candidates.select do |_, signs|
        !signs.empty? && signs.none? { |obligation| counts[obligation] == 1 }
      end.keys
      { objective: objective, scope_decision_ids: scope,
        target_obligations: target.to_a.sort_by do |decision, index, sign|
          [decision.to_s, index.to_i, sign ? 1 : 0]
        end, selected_ids: selected,
        status: status, lower_bound: lower, visited_nodes: visited, reasons: reasons,
        necessary_ids: necessary, interchangeable_ids: interchangeable,
        additional_ids: candidates.keys.sort - selected }
    end

    def format_obligations(obligations)
      obligations.to_a.sort_by do |decision, index, sign|
        [decision.to_s, index.to_i, sign ? 1 : 0]
      end.map(&:inspect).join(", ")
    end

    def integer_limit(key, default)
      value = id(@limits, key)
      value&.to_i&.positive? ? value.to_i : default
    end

    def value(vector, index) = (vector[:values] || vector["values"])[index]
    def id(record, key) = record[key].nil? ? record[key.to_s] : record[key]
    def records(record, key) = Array(id(record, key))
  end
end
