# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
require "pathname"

module Branchproof
  # Terminal renderings grouped around conditions or tests.
  class FocusedReport
    DECISION_TABLE_LABELS = { "true" => "T", "false" => "F", "dont_care" => "-" }.freeze

    def initialize(document:, view:, level:, missing_only: false, coordinator: nil)
      @document = document || {}
      @view = view.to_sym
      unless %i[conditions tests decision_tables].include?(@view)
        raise ArgumentError, "view must be :conditions, :tests, or :decision_tables"
      end

      @level = level.to_i
      @missing_only = missing_only ? true : false
      @index = CoverageIndex.new(document: @document)
      @tests = @index.tests.to_h { |test| [test[:id].to_s, test] }
      @test_name_counts = @index.tests.each_with_object(Hash.new(0)) do |test, counts|
        counts[[test[:name], test[:relative_path], test[:line]]] += 1
      end
      @coordinator = coordinator || Report.from_document(document: @document, level: @level)
    end

    def render
      baseline = fetch(@document, :baseline) || {}
      completeness = fetch(@document, :completeness) || {}
      evidence = fetch(@document, :observations) || {}
      lines = ["Branchproof focused view: #{@view}", "Tests: #{fetch(baseline, :status) || "INCOMPLETE"}",
               (if @index.alternatives.empty?
                  "Values: T=true, F=false, -=short-circuited"
                else
                  "Values: Boolean T=true/F=false; flow T=selected, F=not-selected, -=skipped"
                end)]
      if completeness.values.include?(false) || fetch(baseline, :status).to_s != "PASSED"
        lines << "Warning: failed or incomplete run; observations and proof evidence may be unavailable."
      end
      aborts = fetch(evidence, :abort_counts)
      abort_count = aborts.is_a?(Hash) ? aborts.values.sum(&:to_i) : aborts.to_i
      if abort_count.positive?
        lines << "Warning: #{abort_count} aborted observations; completed vectors do not describe aborted evaluations."
      end
      lines << "Empty groups mean no recorded completed observation."
      lines << ""
      lines.concat(@coordinator.coverage_ladder_lines)
      case @view
      when :conditions
        render_conditions(lines)
        render_alternatives(lines)
      when :decision_tables
        render_decision_tables(lines)
      else
        render_tests(lines)
      end
      unless @view == :decision_tables
        render_unowned(lines)
        render_unsupported(lines)
      end
      Array(fetch(@document, :diagnostics)).each do |diagnostic|
        lines << "Diagnostic: #{@coordinator.diagnostic_message(diagnostic)}"
      end
      lines.join("\n") << "\n"
    end

    private

    def render_conditions(lines)
      rows = @index.conditions
      rows = rows.reject { |row| row[:status].to_s.upcase == "PROVEN" } if @missing_only && @level > 1
      rows.each do |row|
        lines << "Condition: #{row[:expression]}"
        lines << "Location: #{location(row[:relative_path], row[:line], unavailable: "condition line unavailable")}"
        lines << "Decision: #{row[:decision_expression]} (condition #{row[:index]})"
        lines << "Kind: #{row[:kind]}"
        lines << "Context: #{row[:context]}" unless row[:context].to_s.empty?
        status = if @level == 1 && !coverage_available?
                   "NOT CALCULATED"
                 else
                   row[:status] || "NOT_PROVEN"
                 end
        lines << "MC/DC: #{status}"
        if @level >= 2
          lines.concat(@coordinator.condition_coverage_evidence(decision_id: row[:decision_id], condition_id: row[:id]))
        end
        render_group(lines, "Evaluated true by", row[:observed_true], row)
        render_group(lines, "Evaluated false by", row[:observed_false], row)
        render_group(lines, "Short-circuited in", row[:short_circuited], row)
        lines << "  Unattributed observations: #{row[:unattributed]}" if row[:unattributed].to_i.positive?
        if @level >= 2 && row[:supporting_set].any?
          lines << "  Supporting test set: #{row[:supporting_set].map { |id| test_label(id) }.join(", ")}"
          lines << "  Tests outside this MC/DC evidence set may provide other coverage."
        end
        render_constraint(lines, row) if @level >= 3 && row[:constraint_result]
        if @level >= 3 && row[:witness_vector_ids].any?
          lines << "  Witness observations (owners of example evidence):"
          row[:witness_vector_ids].each do |id|
            vector = row[:vectors].values.flatten.find { |item| item[:id].to_s == id.to_s }
            next unless vector

            owners = Array(vector[:test_ids]).map { |test_id| test_label(test_id) }.uniq.sort
            owners << "unattributed" if vector[:unattributed_count].to_i.positive?
            owners = owners.join(", ")
            lines << "    [#{values(vector)}] => #{vector[:outcome] ? "T" : "F"} — #{owners}"
          end
        end
        lines << ""
      end
      lines << "No missing conditions" if @missing_only && rows.empty?
    end

    def coverage_available?
      analysis = fetch(@document, :analysis)
      analysis && fetch(analysis, :coverage)
    end

    def render_constraint(lines, row)
      lines << @coordinator.condition_explanation(decision_id: row[:decision_id], condition_id: row[:id])
    end

    def render_group(lines, heading, ids, _row)
      lines << "  #{heading}:"
      if ids.empty?
        lines << "    none recorded"
      else
        ids.each { |id| lines << "    #{test_label(id)}" }
      end
    end

    # One block per Boolean decision that carries a decision table. With
    # --missing-only only uncovered, non-impossible rules remain: a rule proven
    # impossible is not a missing obligation.
    def render_decision_tables(lines)
      rows = @index.decision_tables
      rendered = 0
      impossible = 0
      rows.each do |row|
        impossible += row[:impossible_rules].to_i
        rules = @missing_only ? row[:rules].select { |rule| rule[:coverage].to_s == "missing" } : row[:rules]
        next if @missing_only && rules.empty?

        rendered += 1
        lines << "Decision: #{row[:decision_expression]}"
        lines << "Location: #{location(row[:relative_path], row[:line], unavailable: "decision line unavailable")}"
        lines << "Context: #{row[:context]}" unless row[:context].to_s.empty?
        if row[:status].to_s != "calculated"
          lines << "Decision Table: NOT CALCULATED"
          lines << "Reason: #{row[:reason]}"
          lines << ""
          next
        end
        lines << "Decision Table: #{row[:covered_rules]}/#{row[:required_rules]} rules covered" \
                 "#{" (#{row[:percentage]}%)" unless row[:percentage].nil?}"
        rules.each { |rule| render_decision_table_rule(lines, row, rule) }
        lines << ""
      end
      lines << "No missing decision-table rules" if @missing_only && rendered.zero?
      return unless impossible.positive?

      lines << "#{impossible} statically impossible rule#{"s" unless impossible == 1} excluded"
    end

    def render_decision_table_rule(lines, row, rule)
      signature = rule[:conditions].map { |item| DECISION_TABLE_LABELS.fetch(item.to_s, item.to_s) }.join
      status = rule[:coverage].to_s.upcase
      lines << "  #{rule[:label]} #{signature} => #{rule[:outcome] ? "T" : "F"}  #{status}"
      row[:conditions].each_with_index do |expression, index|
        requirement = case rule[:conditions][index].to_s
                      when "true" then "truthy"
                      when "false" then "falsey"
                      else next
                      end
        lines << "    #{expression} = #{requirement}"
      end
      lines << "    Expected decision: #{rule[:outcome] ? "true" : "false"}"
      if rule[:coverage].to_s == "covered"
        owners = Array(rule[:tests]).map { |id| test_label(id) }
        owners << "unattributed" if rule[:unattributed_count].to_i.positive?
        lines << "    Tests: #{owners.empty? ? "none recorded" : owners.uniq.join(", ")}"
      else
        lines << "    Tests: NOT COVERED"
      end
      lines << "    Reachability: #{reachability_label(rule)}"
      return if rule[:reachability_reason].to_s.empty?

      lines << "    Reason: #{Constraints.message(rule[:reachability_reason])}"
    end

    def reachability_label(rule)
      rule[:reachability].to_s == "statically_impossible" ? "STATICALLY IMPOSSIBLE" : rule[:reachability].to_s
    end

    def render_alternatives(lines)
      rows = @index.alternatives
      rows = rows.select { |row| row[:missing] || row[:status].to_s != "covered" } if @missing_only && @level > 1
      rows.each do |row|
        lines << "Alternative #{row[:index]}: #{row[:expression]}"
        lines << "Location: #{location(row[:relative_path], row[:line],
                                       unavailable: "alternative location unavailable")}"
        lines << "Decision: #{row[:decision_expression]} (alternative #{row[:index]})"
        lines << "Kind: #{row[:kind]}"
        lines << "Context: #{row[:context]}" unless row[:context].to_s.empty?
        lines << "Selection: #{row[:status] || "NOT_CALCULATED"}"
        lines << "MC/DC: N/A (not applicable)"
        render_alternative_group(lines, "Selected by", row[:selected])
        render_alternative_group(lines, "Not selected by", row[:not_selected])
        render_alternative_group(lines, "Skipped in", row[:skipped])
        if row[:missing]
          lines << "  Missing alternative: #{row[:expression]}"
          lines << "  Need selection of: #{row[:expression]}"
        end
        lines << ""
      end
      lines << "No missing alternatives" if @missing_only && rows.empty?
    end

    def render_alternative_group(lines, heading, evidence)
      evidence ||= {}
      ids = Array(evidence[:test_ids]).map { |id| test_label(id) }
      ids << "unattributed" if evidence[:unattributed_count].to_i.positive?
      lines << "  #{heading}: #{ids.empty? ? "none recorded" : ids.uniq.join(", ")}"
    end

    def render_tests(lines)
      rows = @index.tests
      missing_ids = @index.conditions.reject { |row| row[:status].to_s.upcase == "PROVEN" }.map { |row| row[:id] }
      missing_alternative_ids = @index.alternatives.select { |row| row[:missing] || row[:status].to_s != "covered" }
                                      .map { |row| row[:alternative_id] }
      rows.each { |row| render_test_row(lines, row, missing_ids, missing_alternative_ids) }
    end

    def render_test_row(lines, row, missing_ids, missing_alternative_ids = [])
      observations = row[:observations]
      if @missing_only
        observations = observations.select do |observation|
          missing_ids.include?(observation[:condition_id]) ||
            missing_alternative_ids.include?(observation[:alternative_id])
        end
        return if observations.empty?
      end
      lines << "Test: #{row[:name]}"
      lines << "Location: #{location(row[:relative_path], row[:line], unavailable: "location unavailable")}"
      lines << "Status: #{row[:status] || "unknown"}"
      lines << "Phases: #{row[:phases].join(", ")}" unless row[:phases].empty?
      render_test_observations(lines, observations)
      lines << ""
    end

    def render_test_observations(lines, observations)
      if observations.empty?
        lines << "  No recorded completed condition observations"
        return
      end
      grouped = observations.group_by { |observation| observation[:alternative_id] || observation[:condition_id] }
      grouped.each_value do |items|
        observation = items.first
        phases = items.flat_map { |item| item[:phases] }.uniq.sort.join(", ")
        if observation[:alternative_id]
          states = items.map { |item| item[:alternative_state] }.uniq.join(", ")
          alternative_location = location(observation[:relative_path], observation[:line],
                                          unavailable: "alternative location unavailable")
          lines << "  Alternative #{observation[:alternative_id]}: #{observation[:expression]} " \
                   "(#{alternative_location}): #{states}; phases: #{phases}"
        else
          observed_values = items.map { |item| item[:value] }.uniq
          label = observed_values.all?(&:nil?) ? "short-circuited-only" : "evaluated"
          label += "; owns canonical witness evidence" if @level > 1 && items.any? { |item| item[:owns_witness] }
          signs = values(values: observed_values)
          condition_location = location(observation[:relative_path], observation[:line],
                                        unavailable: "condition line unavailable")
          lines << "  #{observation[:expression]} (#{condition_location}): #{signs}; #{label}; " \
                   "phases: #{phases}"
        end
      end
    end

    def render_unowned(lines)
      rows = @index.conditions
      rows = rows.reject { |row| row[:status] == "PROVEN" } if @missing_only
      groups = { "Unexecuted conditions" => rows.select { |row| row[:unexecuted] },
                 "Unattributed evidence" => rows.select { |row| row[:unattributed].positive? } }
      alternative_rows = @index.alternatives
      alternative_rows = alternative_rows.reject { |row| row[:status].to_s == "covered" } if @missing_only
      unless alternative_rows.empty?
        groups["Unexecuted alternatives"] = alternative_rows.select do |row|
          row[:selected][:observed] == false && row[:not_selected][:observed] == false
        end
        groups["Unattributed alternative evidence"] = alternative_rows.select do |row|
          %i[selected not_selected skipped].any? { |state| row[state][:unattributed_count].to_i.positive? }
        end
      end
      groups.each do |heading, conditions|
        next if conditions.empty?

        lines << "#{heading}:"
        conditions.each do |row|
          unavailable = row[:alternative_id] ? "alternative location unavailable" : "condition line unavailable"
          lines << "  #{row[:expression]} (#{location(row[:relative_path], row[:line], unavailable: unavailable)})"
        end
      end
    end

    def render_unsupported(lines)
      inventory = fetch(@document, :source_inventory) || {}
      sources = Array(fetch(inventory, :source_units)).to_h { |source| [fetch(source, :source_id), source] }
      excluded = Array(fetch(inventory, :decisions)).select do |decision|
        fetch(decision, :support_status) == "UNSUPPORTED"
      end
      return if excluded.empty?

      lines << "Unsupported conditions (MC/DC unavailable):"
      excluded.each do |decision|
        source = sources[fetch(decision, :source_id)] || {}
        path = fetch(source, :relative_path)
        path = nil if path && Pathname.new(path).absolute?
        conditions = Array(fetch(decision, :conditions))
        conditions = [{ expression: fetch(decision, :expression) }] if conditions.empty?
        conditions.each do |condition|
          label = location(path, fetch(condition, :line), unavailable: "condition line unavailable")
          lines << "  #{fetch(condition, :expression)} (#{label})"
        end
      end
    end

    def location(path, line, unavailable: "location unavailable")
      return "location unavailable" if path.to_s.empty?
      return "#{path}: #{unavailable}" if line.nil?

      "#{path}:#{line}"
    end

    def values(vector)
      Array(vector[:values]).map do |item|
        if item.nil?
          "-"
        else
          (item ? "T" : "F")
        end
      end.join
    end

    def test_label(id)
      test = @tests[id.to_s]
      return id.to_s unless test

      label = "#{test[:name]} (#{location(test[:relative_path], test[:line])})"
      duplicates = @test_name_counts[[test[:name], test[:relative_path], test[:line]]]
      duplicates > 1 ? "#{label} [#{id}]" : label
    end

    def fetch(hash, key)
      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
  end
end

# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
