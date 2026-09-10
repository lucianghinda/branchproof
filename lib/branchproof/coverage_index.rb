# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/BlockLength

require "pathname"

module Branchproof
  # Derives condition- and test-oriented rows from one report document.
  class CoverageIndex
    attr_reader :conditions, :alternatives, :tests

    def initialize(document:)
      @document = symbolize(document || {})
      @inventory = symbolize(@document[:source_inventory] || @document[:inventory] || {})
      @evidence = symbolize(@document[:observations] || @document[:evidence] || {})
      @analysis = symbolize(@document[:analysis] || {})
      @baseline = symbolize(@document[:baseline] || {})
      @vectors = records(@evidence, :vectors)
      @vectors_by_decision = @vectors.group_by { |vector| vector[:decision_id].to_s }
      @vectors_by_id = @vectors.to_h { |vector| [vector[:id].to_s, vector] }
      @analysis_by_decision = records(@analysis, :decisions).to_h { |decision| [decision[:decision_id].to_s, decision] }
      @source_units_by_id = records(@inventory, :source_units).to_h { |unit| [unit[:source_id].to_s, unit] }
      @test_locations = symbolize(@document[:run_metadata] || {})[:test_locations] || {}
      @tests_by_id = {}
      (records(@evidence, :tests) + records(@baseline, :tests)).each do |test|
        id = test[:id].to_s
        @tests_by_id[id] = (@tests_by_id[id] || {}).merge(test) unless id.empty?
      end
      @conditions = build_conditions.freeze
      @alternatives = build_alternatives.freeze
      @tests = build_tests.freeze
    end

    private

    def build_conditions
      decisions = records(@inventory, :decisions)
      rows = decisions.flat_map do |decision|
        next [] if decision[:support_status].to_s == "UNSUPPORTED"

        source = @source_units_by_id[decision[:source_id].to_s] || {}
        result_map = records(analysis_for(decision), :condition_results).to_h do |result|
          [result[:condition_id].to_s, result]
        end
        records(decision, :conditions).map do |condition|
          condition = symbolize(condition)
          result = symbolize(result_map[condition[:id].to_s] || {})
          pair = Array(result[:canonical_pair])
          vectors = @vectors_by_decision[decision[:id].to_s] || []
          observations = { true => [], false => [], short_circuited: [], unattributed: [] }
          vectors.each do |vector|
            value = vector_values(vector)[condition[:index].to_i]
            if value.nil?
              observations[:short_circuited] << vector
            elsif value == true
              observations[true] << vector
            elsif value == false
              observations[false] << vector
            end
            observations[:unattributed] << vector if vector[:unattributed_count].to_i.positive?
          end
          {
            id: condition[:id], decision_id: decision[:id], index: condition[:index],
            expression: condition[:expression],
            line: condition[:line], column: condition[:column], relative_path: relative_path(source[:relative_path]),
            decision_expression: decision[:expression], kind: decision_kind(decision), context: decision[:context],
            status: @document[:analysis] ? (result[:status] || "NOT_PROVEN") : "NOT CALCULATED",
            observed_true: test_ids(observations[true]), observed_false: test_ids(observations[false]),
            short_circuited: test_ids(observations[:short_circuited]),
            unattributed: observations[:unattributed].sum { |vector| vector[:unattributed_count].to_i },
            witness_vector_ids: pair, witness_owners: pair.flat_map { |id| owners_for(id) }.uniq.sort,
            witness_owner_details: pair.flat_map { |id| owner_details_for(id) }.uniq.sort,
            vectors: observations, constraint_result: result[:constraint_result],
            supporting_set: supporting_set_for(decision[:id]), unexecuted: vectors.empty?
          }
        end
      end
      rows.sort_by do |row|
        [row[:relative_path].to_s, row[:line].to_i, row[:column].to_i,
         row[:decision_id].to_s, row[:index].to_i]
      end
    end

    def build_alternatives
      records(@inventory, :decisions).flat_map do |decision|
        next [] if decision[:support_status].to_s == "UNSUPPORTED"
        next [] if boolean_decision?(decision)

        source = @source_units_by_id[decision[:source_id].to_s] || {}
        coverage = symbolize(analysis_for(decision)[:coverage] || {})[:alternative] || {}
        coverage_rows = records(coverage, :alternatives).to_h { |row| [row[:alternative_id].to_s, row] }
        vectors = @vectors_by_decision[decision[:id].to_s] || []
        records(decision, :alternatives).map do |alternative|
          alternative = symbolize(alternative)
          evidence = { selected: [], not_selected: [], skipped: [] }
          vectors.each do |vector|
            value = vector_values(vector)[alternative[:index].to_i]
            state = if value.nil?
                      :skipped
                    else
                      (value ? :selected : :not_selected)
                    end
            evidence[state] << vector
          end
          row = symbolize(coverage_rows[alternative[:id].to_s] || {})
          {
            id: alternative[:id], alternative_id: alternative[:id], decision_id: decision[:id],
            index: alternative[:index], expression: alternative[:expression],
            line: alternative[:line], column: alternative[:column],
            relative_path: relative_path(source[:relative_path]),
            decision_expression: decision[:expression], kind: decision_kind(decision),
            context: decision[:context],
            status: @document[:analysis] ? alternative_status(row, evidence) : "NOT CALCULATED",
            selected: row[:selected] || evidence_bucket(evidence[:selected]),
            not_selected: row[:not_selected] || evidence_bucket(evidence[:not_selected]),
            skipped: row[:skipped] || evidence_bucket(evidence[:skipped]),
            vectors: evidence, missing: missing_alternative?(coverage, alternative)
          }
        end
      end
    end

    def build_tests
      by_id = @tests_by_id.transform_values do |test|
        { id: test[:id], name: display_name(test), relative_path: test_location(test)[0], line: test_location(test)[1],
          status: test[:status], phases: Array(test[:phase_counts]).to_h.keys.sort,
          observations: [], owns_witness: false }
      end
      @alternatives.each do |alternative|
        alternative[:vectors].each do |kind, vectors|
          vectors.each do |vector|
            Array(vector[:test_ids]).each do |id|
              row = by_id[id.to_s] ||= { id: id, name: id, relative_path: nil, line: nil, status: "unknown",
                                         phases: [], observations: [], owns_witness: false }
              phase_map = symbolize(vector[:phases_by_test] || {})
              phases = phase_map[id.to_s] || phase_map[id.to_sym] || []
              row[:phases] |= Array(phases).map(&:to_s)
              row[:observations] << { alternative_id: alternative[:id], expression: alternative[:expression],
                                      relative_path: alternative[:relative_path], line: alternative[:line],
                                      value: kind == :skipped ? nil : (kind == :selected), kind: :alternative,
                                      alternative_state: kind.to_s, phases: phases.map(&:to_s).sort,
                                      owns_witness: false }
            end
          end
        end
      end
      @conditions.each do |condition|
        condition[:vectors].each do |kind, vectors|
          next if kind == :unattributed

          vectors.each do |vector|
            Array(vector[:test_ids]).each do |id|
              row = by_id[id.to_s] ||= { id: id, name: id, relative_path: nil, line: nil, status: "unknown",
                                         phases: [], observations: [], owns_witness: false }
              phase_map = symbolize(vector[:phases_by_test] || {})
              phases = phase_map[id.to_s] || phase_map[id.to_sym] || []
              row[:phases] |= Array(phases).map(&:to_s)
              row[:observations] << { condition_id: condition[:id], expression: condition[:expression],
                                      relative_path: condition[:relative_path], line: condition[:line],
                                      value: kind == :short_circuited ? nil : (kind == true), kind: kind,
                                      phases: phases.map(&:to_s).sort,
                                      owns_witness: condition[:witness_vector_ids].include?(vector[:id]) }
              row[:owns_witness] = true if condition[:witness_vector_ids].include?(vector[:id])
            end
          end
        end
      end
      by_id.each_value do |row|
        row[:observations].uniq!
        row[:phases] = row[:phases].map(&:to_s).uniq.sort
      end
      by_id.values.sort_by { |row| [row[:name].to_s, row[:relative_path].to_s, row[:line].to_i, row[:id].to_s] }
    end

    def analysis_for(decision)
      @analysis_by_decision[decision[:id].to_s] || {}
    end

    def boolean_decision?(decision)
      decision_kind(decision) == "boolean"
    end

    def decision_kind(decision)
      kind = decision[:kind].to_s
      kind.empty? ? "boolean" : kind
    end

    def evidence_bucket(vectors)
      evidence = vectors.map do |vector|
        { vector_id: vector[:id].to_s, test_ids: Array(vector[:test_ids]).map(&:to_s).uniq.sort,
          unattributed_count: vector[:unattributed_count].to_i }
      end
      { observed: !vectors.empty?, vector_ids: evidence.map { |item| item[:vector_id] }.uniq.sort,
        test_ids: evidence.flat_map { |item| item[:test_ids] }.uniq.sort,
        unattributed_count: evidence.sum { |item| item[:unattributed_count] } }
    end

    def missing_alternative?(coverage, alternative)
      Array(coverage[:missing_alternatives]).map(&:to_s).include?(alternative[:id].to_s)
    end

    def alternative_status(row, evidence)
      status = row[:status].to_s
      return status unless status.empty?

      evidence[:selected].empty? ? "unexecuted" : "covered"
    end

    def supporting_set_for(decision_id)
      Array(@document[:minima] || @document["minima"]).filter_map do |minimum|
        minimum = symbolize(minimum)
        next unless minimum[:objective].to_s == "tests"
        next unless Array(minimum[:scope_decision_ids]).map(&:to_s).include?(decision_id.to_s)

        Array(minimum[:selected_ids]).map(&:to_s).sort
      end.first || []
    end

    def owners_for(vector_id)
      vector = @vectors_by_id[vector_id.to_s]
      Array(vector && vector[:test_ids]).map { |id| display_name(@tests_by_id[id.to_s] || { id: id }) }
    end

    def owner_details_for(vector_id)
      vector = @vectors_by_id[vector_id.to_s]
      Array(vector && vector[:test_ids]).map do |id|
        test = @tests_by_id[id.to_s] || { id: id }
        name = display_name(test)
        path, line = test_location(test)
        path && line ? "#{name} (#{path}:#{line})" : name
      end
    end

    def test_ids(vectors) = vectors.flat_map { |vector| Array(vector[:test_ids]) }.map(&:to_s).uniq.sort
    def vector_values(vector) = Array(vector[:values])
    def records(hash, key) = Array(hash[key] || hash[key.to_s]).map { |item| symbolize(item) }

    def display_name(test)
      return "#{test[:class_name]}##{test[:method_name]}" if test[:class_name] && test[:method_name]

      (test[:name] || test[:id]).to_s
    end

    def test_location(test)
      saved = symbolize(@test_locations[test[:id].to_s] || @test_locations[test[:id].to_sym] || {})
      return [relative_path(saved[:relative_path]), saved[:line]] unless saved.empty?

      source = symbolize(test[:source] || {})
      path = source[:relative_path] || source[:path] || test[:source_path]
      [relative_path(path), source[:line] || test[:line] || test[:source_line]]
    end

    def relative_path(path)
      return nil if path.nil? || path.to_s.empty?
      return path.to_s unless Pathname.new(path.to_s).absolute?

      root = @inventory[:root] || symbolize(@document[:run_metadata] || {})[:project_root]
      return nil unless root && Pathname.new(root.to_s).absolute?

      Pathname.new(path.to_s).relative_path_from(Pathname.new(root.to_s)).to_s
    rescue ArgumentError
      nil
    end

    def symbolize(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), result| result[key.to_sym] = symbolize(item) }
      when Array then value.map { |item| symbolize(item) }
      else value
      end
    end
  end
end

# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/BlockLength
