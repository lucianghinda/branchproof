# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
require_relative "coverage_index"
require_relative "report_selection"

module Branchproof
  # Ranks supported decisions and source files by missing coverage obligations.
  #
  # Order: unexecuted decisions first, then more missing obligations
  # (decision-table rules, unproven MC/DC conditions, missing alternatives),
  # then source path, line, column, and ID. The order is a count, not a risk
  # estimate. Unsupported decisions are counted but never ranked.
  class SummaryRanking
    Decision = Struct.new(:id, :relative_path, :line, :column, :expression, :kind, :context, :unexecuted,
                          :missing_rules, :required_rules, :table_calculated, :unproven_conditions,
                          :conditions, :missing_alternatives, :alternatives, :test_ids,
                          keyword_init: true) do
      def missing_total = missing_rules.length + unproven_conditions.length + missing_alternatives.length
      def gap? = unexecuted || missing_total.positive?

      # One new observation covers at most one missing rule, so missing rules
      # are an exact case count. Without missing rules (no table, or only
      # impossible rules left), each unproven condition or alternative counts.
      def cases_to_test
        return missing_rules.length if rule_cases?

        unproven_conditions.length + missing_alternatives.length
      end

      def rule_cases? = table_calculated && !missing_rules.empty?
    end

    SourceFile = Struct.new(:relative_path, :decisions, keyword_init: true) do
      def gaps = decisions.count(&:gap?)
      def unexecuted = decisions.count(&:unexecuted)
      def missing_rules = decisions.sum { |decision| decision.missing_rules.length }
      def required_rules = decisions.sum(&:required_rules)
      def unproven_conditions = decisions.sum { |decision| decision.unproven_conditions.length }
      def conditions = decisions.sum { |decision| decision.conditions.length }
      def missing_alternatives = decisions.sum { |decision| decision.missing_alternatives.length }
      def alternatives = decisions.sum { |decision| decision.alternatives.length }
      def missing_total = decisions.sum(&:missing_total)
    end

    attr_reader :index

    def initialize(document:, selection: ReportSelection.new)
      @document = document || {}
      @selection = selection
      @index = CoverageIndex.new(document: @document)
    end

    def available?
      analysis = fetch(@document, :analysis)
      analysis.respond_to?(:key?) && !fetch(analysis, :decisions).nil?
    end

    # All supported decisions in the selection, ranked.
    def decisions
      @decisions ||= build_decisions.sort_by { |decision| decision_key(decision) }.freeze
    end

    def gaps
      decisions.select(&:gap?)
    end

    def files
      @files ||= begin
        files = decisions.group_by(&:relative_path).map do |path, items|
          SourceFile.new(relative_path: path, decisions: items)
        end
        files.sort_by { |file| file_key(file) }.freeze
      end
    end

    def unsupported_count
      inventory_decisions.count { |decision| fetch(decision, :support_status).to_s == "UNSUPPORTED" }
    end

    private

    def build_decisions
      conditions = @index.conditions.group_by { |row| row[:decision_id].to_s }
      alternatives = @index.alternatives.group_by { |row| row[:decision_id].to_s }
      tables = @index.decision_tables.to_h { |row| [row[:decision_id].to_s, row] }
      sources = inventory_sources
      selected_ids = @selection.decision_filter_active? ? @selection.selected_decision_ids(@document) : nil
      selected_id_set = selected_ids&.to_h { |id| [id, true] }
      inventory_decisions.filter_map do |decision|
        id = fetch(decision, :id).to_s
        next if fetch(decision, :support_status).to_s == "UNSUPPORTED"
        next if selected_id_set && !selected_id_set.key?(id)

        condition_rows = conditions.fetch(id, [])
        alternative_rows = alternatives.fetch(id, [])
        table = tables[id]
        calculated = table && table[:status].to_s == "calculated"
        source = sources[fetch(decision, :source_id).to_s] || {}
        Decision.new(
          id: id, relative_path: display_path(fetch(source, :relative_path)),
          line: fetch(decision, :line), column: fetch(decision, :column),
          expression: fetch(decision, :expression).to_s, kind: kind(decision), context: fetch(decision, :context),
          unexecuted: !executed_decision_ids.include?(id),
          missing_rules: calculated ? table[:rules].select { |rule| rule[:coverage].to_s == "missing" } : [],
          required_rules: calculated ? table[:required_rules].to_i : 0, table_calculated: calculated ? true : false,
          unproven_conditions: condition_rows.reject { |row| row[:status].to_s.upcase == "PROVEN" },
          conditions: condition_rows,
          missing_alternatives: alternative_rows.select { |row| row[:missing] }, alternatives: alternative_rows,
          test_ids: reaching_test_ids(condition_rows, alternative_rows)
        )
      end
    end

    def reaching_test_ids(condition_rows, alternative_rows)
      ids = condition_rows.flat_map { |row| row[:observed_true] + row[:observed_false] + row[:short_circuited] }
      ids += alternative_rows.flat_map do |row|
        %i[selected not_selected skipped].flat_map { |state| Array((row[state] || {})[:test_ids]) }
      end
      ids.map(&:to_s).uniq.sort
    end

    def decision_key(decision)
      [decision.unexecuted ? 0 : 1, -decision.missing_total, decision.relative_path.to_s,
       decision.line.to_i, decision.column.to_i, decision.id]
    end

    def file_key(file)
      [-file.unexecuted, -file.missing_total, file.relative_path.to_s]
    end

    def executed_decision_ids
      @executed_decision_ids ||= Array(fetch(fetch(@document, :observations) || {}, :vectors))
                                 .to_set { |vector| fetch(vector, :decision_id).to_s }
    end

    def kind(decision)
      value = fetch(decision, :kind).to_s
      value.empty? ? "boolean" : value
    end

    def display_path(path)
      return nil if path.to_s.empty? || Pathname.new(path.to_s).absolute?

      path.to_s
    end

    def inventory
      fetch(@document, :source_inventory) || fetch(@document, :inventory) || {}
    end

    def inventory_decisions = Array(fetch(inventory, :decisions))

    def inventory_sources
      Array(fetch(inventory, :source_units)).to_h { |unit| [fetch(unit, :source_id).to_s, unit] }
    end

    def fetch(hash, key)
      return nil unless hash.respond_to?(:key?)

      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
