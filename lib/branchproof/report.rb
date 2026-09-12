# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require "json"
require "pathname"

module Branchproof
  # Renders versioned terminal and JSON analysis reports.
  class Report
    SCHEMA_VERSION = "1.3"
    CRITERION_VERSION = "masking_occurrence_v1"
    DECISION_TABLE_LABELS = { "true" => "T", "false" => "F", "dont_care" => "-" }.freeze
    DECISION_TABLE_STATUS_LABELS = { "covered" => "COVERED", "missing" => "MISSING",
                                     "excluded" => "EXCLUDED" }.freeze

    def initialize(inventory:, evidence:, analysis:, minima:, baseline:, diagnostics:, level: 3, missing_only: false,
                   view: :decisions, run_metadata: {}, saved_document: nil)
      raise ArgumentError, "level must be 1, 2, or 3" unless [1, 2, 3].include?(level.to_i)
      unless %i[decisions conditions tests decision_tables].include?(view.to_sym)
        raise ArgumentError, "view must be :decisions, :conditions, :tests, or :decision_tables"
      end

      @inventory = inventory || {}
      @evidence = evidence || {}
      @analysis = analysis
      @minima = Array(minima)
      @baseline = baseline || {}
      @diagnostics = Array(diagnostics)
      @level = level.to_i
      @missing_only = missing_only ? true : false
      @view = view.to_sym
      @run_metadata = run_metadata || {}
      @saved_document = saved_document
    end

    def self.from_document(document:, level: nil, view: :decisions, missing_only: false)
      data = document || {}
      new(inventory: data[:source_inventory] || data["source_inventory"],
          evidence: data[:observations] || data["observations"],
          analysis: data[:analysis] || data["analysis"], minima: data[:minima] || data["minima"],
          baseline: data[:baseline] || data["baseline"], diagnostics: data[:diagnostics] || data["diagnostics"],
          level: level || (data[:analysis] || data["analysis"] ? 3 : 1), view: view, missing_only: missing_only,
          run_metadata: data[:run_metadata] || data["run_metadata"], saved_document: data)
    end

    def write(io:, format:)
      format = format.to_sym
      raise ArgumentError, "format must be :terminal or :json" unless %i[terminal json].include?(format)

      io.write(format == :json ? JSON.generate(json_document) : terminal_document)
      nil
    end

    # Shares the existing missing-case wording with focused terminal views.
    def condition_explanation(decision_id:, condition_id:)
      decision = inventory_decisions.find { |item| value(item, :id).to_s == decision_id.to_s }
      return "" unless decision

      condition = Array(value(decision, :conditions)).find { |item| value(item, :id).to_s == condition_id.to_s }
      return "" unless condition

      @terminal_ids ||= terminal_ids
      condition_detail(decision, condition, condition_result(decision, condition))
    end

    # Formats source context consistently in live and saved terminal views.
    def diagnostic_message(diagnostic)
      message = value(diagnostic, :message) || value(diagnostic, :code)
      source_id = value(diagnostic, :source_id)
      return message unless source_id

      source = source_for(diagnostic)
      path = value(source, :relative_path) || source_id
      prefix = %w[not_instrumented unsupported_source].include?(value(diagnostic, :code).to_s) ? "Skipped " : ""
      "#{prefix}#{path}: #{message}"
    end

    # Returns condition-value evidence for focused renderers without exposing
    # the report's internal document traversal or mutating saved records.
    def condition_coverage_evidence(decision_id:, condition_id:)
      decision = inventory_decisions.find { |item| value(item, :id).to_s == decision_id.to_s }
      condition = Array(value(decision, :conditions)).find do |item|
        value(item, :id).to_s == condition_id.to_s
      end
      coverage = value(condition_result(decision, condition), :coverage)
      return [] unless coverage

      @terminal_ids ||= terminal_ids
      lines = Array(value(coverage, :values)).map do |entry|
        value_label = value(entry, :value) ? "true" : "false"
        owners = Array(value(entry, :test_ids)).map { |id| test_label(id) }
        owners << "unattributed" if value(entry, :unattributed_count).to_i.positive?
        evidence = owners.empty? ? "none recorded" : owners.uniq.join(", ")
        "  Value #{value_label}: #{value(entry, :observed) ? "observed" : "missing"}; tests: #{evidence}"
      end
      missing = Array(value(coverage, :missing_values))
      unless missing.empty?
        lines << "  Missing values: #{missing.map { |item| item ? "true" : "false" }.join(", ")}"
      end
      lines
    end

    def exit_code
      return 2 unless usage_valid?

      status = value(@baseline, :status).to_s.upcase
      return 2 if %w[ERROR INCOMPLETE].include?(status)
      return 1 if status == "FAILED"
      return 2 unless status == "PASSED" && value(@baseline, :finalized) == true
      return 2 if @saved_document && (value(@saved_document, :completeness) || {}).values.include?(false)

      eligible = metrics[:eligible_conditions].positive? || metrics[:eligible_alternatives].positive?
      return 2 unless eligible
      return 2 unless valid_for_requested_level?

      0
    end

    private

    def json_document
      return normalize(@saved_document) if @saved_document

      normalize(schema_version: SCHEMA_VERSION,
                tool_version: (defined?(Branchproof::VERSION) ? Branchproof::VERSION : "unknown"),
                criterion_version: CRITERION_VERSION, runtime: RUBY_DESCRIPTION,
                run_ids: Array(value(@evidence, :run_ids)),
                source_inventory: inventory_with_default_kinds, baseline: @baseline, observations: @evidence,
                analysis: @analysis, minima: @minima, metrics: metrics,
                diagnostics: @diagnostics, completeness: completeness,
                run_metadata: @run_metadata)
    end

    def terminal_document
      unless @view == :decisions
        return FocusedReport.new(document: json_document, view: @view, level: @level,
                                 missing_only: @missing_only, coordinator: self).render
      end

      @terminal_ids = terminal_ids
      lines = ["Branchproof #{defined?(Branchproof::VERSION) ? Branchproof::VERSION : "unknown"}",
               "Tests: #{baseline_status} (#{baseline_test_counts})",
               terminal_coverage_line,
               "Analysis: #{terminal_analysis_status}",
               "Decisions: #{metrics[:supported]} supported, #{metrics[:unsupported]} excluded, " \
               "#{metrics[:unexecuted]} unexecuted (#{metrics[:discovered]} discovered)",
               decision_kind_summary_line,
               "Observations: #{metrics[:completed]} completed, #{metrics[:aborted]} aborted, " \
               "#{metrics[:unattributed]} unattributed",
               values_legend]
      lines.concat(coverage_ladder_lines)
      lines << missing_summary_line if @missing_only
      lines << "Scope: supported decisions, conditions, and alternatives"
      lines << ""
      decisions_to_render.each { |decision| render_decision(lines, decision) }
      render_minima(lines) unless @missing_only
      unless @diagnostics.empty?
        lines << "Diagnostics:"
        @diagnostics.each { |diagnostic| lines << "  - #{diagnostic_message(diagnostic)}" }
      end
      lines.join("\n") << "\n"
    end

    def render_decision(lines, decision)
      source = source_for(decision)
      filename = value(source, :relative_path) || value(source, :absolute_path) || value(decision, :source_id)
      decision_label = "Decision #{short_id(value(decision, :id))} #{filename}:#{value(decision, :line)}"
      lines << decision_label
      lines << "  Decision: #{value(decision, :expression)}"
      lines << "  Kind: #{decision_kind(decision)}"
      context = value(decision, :context)
      lines << "  Context: #{context}" unless context.nil? || context.to_s.empty?
      lines << "  Status: #{value(decision, :support_status) || "SUPPORTED"}"
      unless nonboolean_decision?(decision)
        conditions_to_render(decision).each do |condition|
          result = condition_result(decision, condition)
          detail = condition_detail(decision, condition, result)
          status = if @analysis.nil? || (@level == 1 && !coverage_available?)
                     "NOT CALCULATED"
                   else
                     value(result, :status) || "NOT_PROVEN"
                   end
          lines << "  Condition #{value(condition, :index)}: #{value(condition, :expression)}"
          lines << "    #{status}#{detail}"
          render_condition_coverage(lines, decision, condition, result) if @level >= 2 && coverage_available?
        end
      end
      render_decision_coverage(lines, decision) if coverage_available?
      render_decision_table(lines, decision) if analysis_available? && !nonboolean_decision?(decision)
      vectors_to_render(decision).each do |vector|
        values = Array(value(vector, :values)).map do |item|
          if item.nil?
            "-"
          else
            item ? "T" : "F"
          end
        end.join
        owners = Array(value(vector, :test_ids)).map { |test_id| test_label(test_id) }
        owners << "unattributed" if value(vector, :unattributed_count).to_i.positive?
        vector_label = if nonboolean_decision?(decision)
                         selected = Array(value(vector, :values)).each_with_index.filter_map do |item, index|
                           next unless item

                           alternative = Array(value(decision, :alternatives))[index]
                           value(alternative, :expression) || "alternative #{index}"
                         end
                         "  Vector #{short_id(value(vector, :id))} [#{values}] => selected: #{selected.join(", ")}"
                       else
                         "  Vector #{short_id(value(vector,
                                                    :id))} [#{values}] => " + (if value(vector,
                                                                                        :outcome)
                                                                                 "T"
                                                                               else
                                                                                 "F"
                                                                               end).to_s
                       end
        lines << "#{vector_label} owners=#{owners.join(", ")}"
      end
      lines << ""
    end

    def coverage_status_label(status)
      { "covered" => "PASS", "partial" => "FAIL", "unexecuted" => "UNEXECUTED", "unsupported" => "EXCLUDED" }.fetch(
        status.to_s.downcase, status.to_s.upcase
      )
    end

    def render_decision_coverage(lines, decision)
      if nonboolean_decision?(decision)
        render_alternative_coverage(lines, decision)
        return
      end

      decision_coverage = value(value(analysis_for(decision), :coverage), :decision)
      all_coverage = value(analysis_for(decision), :coverage) || {}
      statuses = [["D", :decision], ["C", :condition], ["C/D", :condition_decision],
                  ["MC/DC", :mcdc], ["DT", :decision_table]].filter_map do |label, key|
        row = value(all_coverage, key)
        status = value(row, :status)
        status ? criterion_status_text(label, row) : nil
      end
      lines << "  Coverage: #{statuses.join(", ")}" unless statuses.empty?
      coverage = decision_coverage
      return unless coverage

      return unless @level >= 2

      Array(value(coverage, :outcomes)).each do |outcome|
        value_label = value(outcome, :value) ? "true" : "false"
        owners = Array(value(outcome, :test_ids)).map { |id| test_label(id) }
        owners << "unattributed" if value(outcome, :unattributed_count).to_i.positive?
        evidence = owners.empty? ? "none recorded" : owners.uniq.join(", ")
        lines << "  Outcome #{value_label}: #{value(outcome, :observed) ? "observed" : "missing"}; tests: #{evidence}"
      end
      missing = Array(value(coverage, :missing_outcomes))
      return if missing.empty?

      lines << "  Missing decision outcomes: #{missing.map do |item|
        item ? "true" : "false"
      end.join(", ")}"
    end

    # Renders the reduced decision table, its runtime overlay, and the
    # actionable detail for rules that no observation reached.
    def render_decision_table(lines, decision)
      table = decision_table_for(decision)
      return unless table

      unless value(table, :status).to_s == "calculated"
        return if value(table, :reason).to_s == "unsupported_decision" && unsupported?(decision)

        lines << "  Decision Table: NOT CALCULATED"
        lines << "  Reason: #{value(table, :reason)}"
        return
      end

      covered = value(table, :covered_rules).to_i
      required = value(table, :required_rules).to_i
      percentage = value(table, :percentage)
      lines << "  Decision Table: #{covered}/#{required} rules covered" \
               "#{" (#{percentage}%)" unless percentage.nil?}"
      impossible = value(table, :impossible_rules).to_i
      lines << "  Statically impossible rules excluded: #{impossible}" if impossible.positive?
      lines << "  Reachability: not analyzed" unless value(table, :reachability_analyzed)
      rules = decision_table_rules_to_render(table)
      lines.concat(decision_table_rows(decision, rules))
      return unless @level >= 2

      rules.each { |rule| render_decision_table_rule(lines, decision, rule) }
    end

    def decision_table_rows(decision, rules)
      return [] if rules.empty?

      conditions = Array(value(decision, :conditions))
      header = ["Rule"] + conditions.map { |condition| truncate(value(condition, :expression).to_s, 24) } +
               %w[Result Status]
      body = rules.map do |rule|
        [value(rule, :label).to_s] +
          Array(value(rule, :conditions)).map { |item| DECISION_TABLE_LABELS.fetch(item.to_s, item.to_s) } +
          [value(rule, :outcome) ? "T" : "F", decision_table_rule_status(rule)]
      end
      return [] unless body.all? { |row| row.length == header.length }

      widths = ([header] + body).transpose.map { |column| column.map(&:length).max }
      ([header] + body).map do |row|
        "    #{row.each_with_index.map { |cell, index| cell.ljust(widths[index]) }.join("  ").rstrip}"
      end
    end

    def decision_table_rule_status(rule)
      DECISION_TABLE_STATUS_LABELS.fetch(value(rule, :coverage).to_s, value(rule, :coverage).to_s.upcase)
    end

    def render_decision_table_rule(lines, decision, rule)
      case value(rule, :coverage).to_s
      when "covered" then render_covered_rule(lines, rule)
      when "excluded" then lines.concat(impossible_rule_lines(rule))
      else lines.concat(missing_rule_lines(decision, rule))
      end
    end

    def render_covered_rule(lines, rule)
      owners = Array(value(rule, :tests)).map { |id| test_label(id) }
      owners << "unattributed" if value(rule, :unattributed_count).to_i.positive?
      lines << "    #{value(rule, :label)} tests: #{owners.empty? ? "none recorded" : owners.uniq.join(", ")}"
      return unless value(rule, :impossible_withdrawn)

      lines << "    #{value(rule, :label)} note: runtime evidence overrides the static impossibility claim " \
               "(#{value(rule, :withdrawn_reason)}); diagnostic constraint_model_conflict"
    end

    # Impossible rules stay visible even though they leave the denominator.
    def impossible_rule_lines(rule)
      ["    #{value(rule, :label)} #{rule_signature(rule)}",
       "    Status:", "      EXCLUDED",
       "    Reachability:", "      STATICALLY IMPOSSIBLE",
       "    Reason:", "      #{Constraints.message(value(rule, :reachability_reason))}"]
    end

    # Condition values only: Branchproof never claims which application inputs
    # would produce them.
    def missing_rule_lines(decision, rule)
      requirements = decision_table_requirements(decision, rule)
      width = requirements.map { |name, _| name.length }.max.to_i
      lines = ["    #{value(rule, :label)}", "    Need:"]
      requirements.each { |name, requirement| lines << "      #{name.ljust(width)} #{requirement}" }
      lines << "    Expected decision:"
      lines << "      #{value(rule, :outcome) ? "true" : "false"}"
      lines << "    Reachability:"
      lines << "      #{value(rule, :reachability)}"
      lines
    end

    def decision_table_requirements(decision, rule)
      Array(value(rule, :conditions)).each_with_index.map do |required, index|
        expression = condition_expression(decision, index) || "condition #{index}"
        requirement = case required.to_s
                      when "true" then "= truthy"
                      when "false" then "= falsey"
                      else "not evaluated (short-circuited)"
                      end
        [expression.to_s, requirement]
      end
    end

    def rule_signature(rule)
      values = Array(value(rule, :conditions)).map { |item| DECISION_TABLE_LABELS.fetch(item.to_s, item.to_s) }
      "#{values.join} => #{value(rule, :outcome) ? "T" : "F"}"
    end

    def decision_table_rules_to_render(table)
      rules = Array(value(table, :rules))
      return rules unless @missing_only

      rules.select { |rule| value(rule, :coverage).to_s == "missing" }
    end

    def decision_table_for(decision)
      value(analysis_for(decision), :decision_table)
    end

    def missing_decision_table_rules(decision)
      table = decision_table_for(decision)
      return [] unless table && value(table, :status).to_s == "calculated"

      Array(value(table, :rules)).select { |rule| value(rule, :coverage).to_s == "missing" }
    end

    def truncate(text, width)
      text.length <= width ? text : "#{text[0, width - 3]}..."
    end

    def render_alternative_coverage(lines, decision)
      coverage = value(value(analysis_for(decision), :coverage), :alternative) || {}
      status = value(coverage, :status)
      required = value(coverage, :required_alternatives) || Array(value(decision, :alternatives)).length
      covered = value(coverage, :covered_alternatives) || 0
      lines << "  Alternatives: #{status || "NOT_CALCULATED"} (#{covered}/#{required})"
      lines << "  MC/DC: N/A (not applicable)"
      rows = Array(value(coverage, :alternatives))
      rows_by_id = rows.to_h { |row| [value(row, :alternative_id).to_s, row] }
      alternatives_to_render(decision).each do |alternative|
        id = value(alternative, :id)
        row = rows_by_id[id.to_s] || {}
        lines << "  Alternative #{value(alternative, :index)}: #{value(alternative, :expression)}"
        render_alternative_state(lines, "Selected", value(row, :selected)) if @level >= 2
        render_alternative_state(lines, "Not selected", value(row, :not_selected)) if @level >= 2
        render_alternative_state(lines, "Skipped", value(row, :skipped)) if @level >= 2
      end
      missing = Array(value(coverage, :missing_alternatives))
      return if missing.empty?

      labels = missing.map do |id|
        alternative = Array(value(decision, :alternatives)).find { |item| value(item, :id).to_s == id.to_s }
        value(alternative, :expression) || short_id(id)
      end
      label = labels.join(", ")
      lines << "  Missing alternatives: #{label}"
      lines << "  Need selection of: #{label}"
    end

    def render_alternative_state(lines, label, evidence)
      evidence ||= {}
      owners = Array(value(evidence, :test_ids)).map { |id| test_label(id) }
      owners << "unattributed" if value(evidence, :unattributed_count).to_i.positive?
      owners = owners.uniq
      status = if value(evidence, :observed)
                 "observed"
               elsif label == "Selected"
                 "missing"
               else
                 "none recorded"
               end
      detail = owners.empty? ? "none recorded" : owners.join(", ")
      lines << "    #{label}: #{status}; tests: #{detail}"
    end

    def render_condition_coverage(lines, _decision, condition, result)
      coverage = value(result, :coverage)
      return unless coverage

      values = Array(value(coverage, :values))
      return if values.empty?

      values.each do |entry|
        value_label = value(entry, :value) ? "true" : "false"
        owners = Array(value(entry, :test_ids)).map { |id| test_label(id) }
        owners << "unattributed" if value(entry, :unattributed_count).to_i.positive?
        evidence = owners.empty? ? "none recorded" : owners.uniq.join(", ")
        lines << "    Value #{value_label}: #{value(entry, :observed) ? "observed" : "missing"}; tests: #{evidence}"
      end
      missing = Array(value(coverage, :missing_values))
      return if missing.empty?

      lines << "    Missing values for #{value(condition, :expression)}: #{missing.map do |item|
        item ? "true" : "false"
      end.join(", ")}"
    end

    def render_minima(lines)
      rows = Array(@minima).map do |minimum|
        objective = value(minimum, :objective)
        scope = Array(value(minimum, :scope_decision_ids)).map { |id| short_id(id) }.join(", ")
        selected = Array(value(minimum, :selected_ids)).map { |id| minimum_member_label(objective, id) }.join(", ")
        label = objective.to_s == "tests" ? "Tests" : "Vectors"
        "  #{label} (#{value(minimum, :status)}, decisions: [#{scope}]): #{selected}"
      end.uniq
      unless rows.empty?
        lines << "Supporting sets:"
        lines.concat(rows)
      end
      lines << "Additional tests outside this MC/DC evidence set may improve coverage." unless @minima.empty?
    end

    def baseline_status
      value(@baseline, :status).to_s.upcase.then { |status| status.empty? ? "INCOMPLETE" : status }
    end

    def baseline_test_counts
      executed = value(@baseline, :executed_tests)
      failed = value(@baseline, :failed_tests) || value(@baseline, :failures) || 0
      skipped = value(@baseline, :skipped_tests) || value(@baseline, :skips) || 0
      "#{executed || 0} tests, #{failed} failed, #{skipped} skipped"
    end

    def terminal_coverage_label
      return "not calculated" if @analysis.nil?

      coverage_label
    end

    def terminal_coverage_line
      return "MC/DC: not calculated" if @analysis.nil?

      "MC/DC: #{terminal_coverage_label} (#{metrics[:proven]}/#{metrics[:eligible_conditions]} conditions proven)"
    end

    def terminal_analysis_status
      return "NOT CALCULATED" if @analysis.nil?

      analysis_status
    end

    def terminal_ids
      ids = []
      ids.concat(inventory_decisions.flat_map { |decision| [value(decision, :id), value(decision, :source_id)] })
      ids.concat(vectors.map { |vector| value(vector, :id) })
      ids.concat(vectors.flat_map { |vector| Array(value(vector, :test_ids)) })
      ids.concat(Array(value(@evidence, :tests)).map { |test| value(test, :id) })
      ids.concat(Array(value(@baseline, :tests)).map { |test| value(test, :id) })
      ids.concat(Array(@minima).flat_map do |minimum|
        Array(value(minimum, :scope_decision_ids)) + Array(value(minimum, :selected_ids))
      end)
      ids.concat(Array(value(@analysis, :decisions)).flat_map do |decision|
        Array(value(decision, :condition_results)).flat_map do |result|
          [value(result, :condition_id), *Array(value(result, :canonical_pair))]
        end
      end)
      ids.concat(Array(value(@analysis, :decisions)).flat_map do |decision|
        Array(value(decision, :condition_results)).flat_map do |result|
          Array(value(value(result, :constraint_result), :candidate_vectors)).map { |vector| value(vector, :id) }
        end
      end)
      ids = ids.compact.map(&:to_s).reject(&:empty?).uniq
      by_prefix = ids.group_by { |id| id[0, 8] }
      ids.to_h do |id|
        prefix_length = 8
        group = by_prefix.fetch(id[0, 8])
        while group.length > 1 && group.map { |item| item[0, prefix_length] }.uniq.length < group.length
          prefix_length += 1
        end
        [id, id.length <= prefix_length ? id : id[0, prefix_length]]
      end
    end

    def short_id(id)
      text = id.to_s
      return text if text.empty? || !@terminal_ids

      @terminal_ids.fetch(text, text)
    end

    def test_label(test_id)
      id = test_id.to_s
      test = test_records_by_id[id]
      return short_id(id) unless test

      class_name = value(test, :class_name)
      method_name = value(test, :method_name)
      name = if class_name && method_name
               "#{class_name}##{method_name}"
             else
               value(test, :name).to_s
             end
      return short_id(id) if name.empty? || name == id

      duplicates = test_records_by_name[name]
      return name if duplicates.length == 1

      location, line = test_location(test)
      suffix = [location, line].compact.join(":")
      same_location = duplicates.count do |item|
        item_location, item_line = test_location(item)
        [item_location, item_line].compact.join(":") == suffix
      end
      return "#{name} (#{suffix})" if !suffix.empty? && same_location == 1

      "#{name} (#{suffix.empty? ? short_id(id) : "#{suffix}, #{short_id(id)}"})"
    end

    def test_location(test)
      saved_location = value(value(@run_metadata, :test_locations), value(test, :id))
      return [relative_test_path(value(saved_location, :relative_path)), value(saved_location, :line)] if saved_location

      location = value(test, :source)
      source_line = nil
      if location.respond_to?(:key?)
        source_line = value(location, :line)
        location = value(location, :relative_path) || value(location, :path)
      end
      location ||= value(test, :source_path)
      location = relative_test_path(location)
      line = value(test, :line) || value(test, :source_line) || source_line
      [location, line]
    end

    def relative_test_path(path)
      return path unless path && Pathname.new(path.to_s).absolute?

      root = value(@inventory, :root) || value(@run_metadata, :project_root)
      return nil unless root && Pathname.new(root.to_s).absolute?

      Pathname.new(path.to_s).relative_path_from(Pathname.new(root.to_s)).to_s
    rescue ArgumentError
      nil
    end

    def minimum_member_label(objective, id)
      objective.to_s == "tests" ? test_label(id) : short_id(id)
    end

    def test_display_name(test)
      class_name = value(test, :class_name)
      method_name = value(test, :method_name)
      class_name && method_name ? "#{class_name}##{method_name}" : value(test, :name).to_s
    end

    def test_records
      @test_records ||= begin
        records = {}
        Array(value(@baseline, :tests)).each { |test| records[value(test, :id).to_s] = test }
        Array(value(@evidence, :tests)).each do |test|
          id = value(test, :id).to_s
          records[id] = records.fetch(id, {}).merge(test)
        end
        records.values
      end
    end

    def test_records_by_id
      @test_records_by_id ||= test_records.to_h { |test| [value(test, :id).to_s, test] }
    end

    def test_records_by_name
      @test_records_by_name ||= test_records.group_by { |test| test_display_name(test) }
    end

    def condition_result(decision, condition)
      condition_results_index.dig(value(decision, :id).to_s, value(condition, :id).to_s)
    end

    def condition_results_index
      @condition_results_index ||= Array(value(@analysis, :decisions)).each_with_object({}) do |item, index|
        by_condition_id = index[value(item, :decision_id).to_s] ||= {}
        Array(value(item, :condition_results)).each do |result|
          by_condition_id[value(result, :condition_id).to_s] = result
        end
      end
    end

    def condition_detail(decision, _condition, result)
      return "" unless result && (@level == 3 || @missing_only)

      pair = value(result, :canonical_pair)
      return " (witness #{Array(pair).map { |id| short_id(id) }.join(" + ")})" if pair

      constraint = value(result, :constraint_result)
      if constraint
        constraints = readable_constraints(decision, constraint)
        detail = constraints.empty? ? value(constraint, :status) : constraints.join(", ")
        statement = value(constraint, :feasibility_statement)
        detail = [detail, statement].compact.reject(&:empty?).join("; ")
        candidates = Array(value(constraint, :candidate_vectors))
        existing = existing_vector_for(constraint)
        unless candidates.empty?
          detail_lines = [" — missing observation"]
          candidates.each do |candidate|
            detail_lines << "      Need an observation where:"
            detail_lines.concat(candidate_requirements(decision, candidate).map { |item| "        #{item}" })
            outcome = value(candidate, :outcome) ? "true" : "false"
            detail_lines << "        Expected decision: #{outcome} [#{vector_values(candidate)}]"
          end
          detail_lines << "      #{statement}" unless statement.to_s.empty?
          detail_lines << "      Compare with: #{existing_vector_context(existing)}"
          return detail_lines.join("\n")
        end
        unless existing.nil?
          owner_ids = Array(value(existing, :test_ids))
          owners = owner_ids.first(2).map { |id| test_label(id) }
          owners << "#{owner_ids.length - 2} more" if owner_ids.length > 2
          owner_detail = owners.empty? ? nil : " (#{owners.join(", ")})"
          detail = [detail, "existing observation: #{short_id(value(existing, :id))}#{owner_detail}"].compact.join("; ")
        end
        return " (missing counterpart: #{detail})" unless detail.empty?
      end

      ""
    end

    def readable_constraints(decision, constraint)
      Array(value(constraint, :constraints)).filter_map do |item|
        if item.respond_to?(:key?)
          index = value(item, :condition_index)
          expression = condition_expression(decision, index) || "condition #{index}"
          required = value(item, :required)
          required = value(item, :value) if required.nil?
          "requires #{expression}=#{required ? "true" : "false"}"
        else
          item.to_s
        end
      end
    end

    def condition_expression(decision, index)
      condition = Array(value(decision, :conditions)).find { |item| value(item, :index).to_i == index.to_i }
      value(condition, :expression)
    end

    def candidate_requirements(decision, candidate)
      Array(value(candidate, :values)).each_with_index.map do |required, index|
        expression = condition_expression(decision, index) || "condition #{index}"
        if required.nil?
          "#{expression} is not evaluated (short-circuited)"
        else
          "#{expression} is #{required ? "truthy" : "falsey"}"
        end
      end
    end

    def vector_values(vector)
      Array(value(vector, :values)).map do |item|
        if item.nil?
          "-"
        elsif item
          "T"
        else
          "F"
        end
      end.join
    end

    def existing_vector_context(existing)
      return "no existing effective observation" unless existing

      owner_ids = Array(value(existing, :test_ids))
      owners = owner_ids.first(2).map { |id| test_label(id) }
      owners << "#{owner_ids.length - 2} more" if owner_ids.length > 2
      context = "[#{vector_values(existing)}] => #{value(existing, :outcome) ? "true" : "false"}"
      owners.empty? ? context : "#{context} (#{owners.join(", ")})"
    end

    def existing_vector_for(constraint)
      id = value(constraint, :existing_vector_id).to_s
      return if id.empty?

      vectors_by_id[id]
    end

    def vectors_by_id
      @vectors_by_id ||= vectors.to_h { |vector| [value(vector, :id).to_s, vector] }
    end

    def values_legend
      return "Values: T=true, F=false, -=short-circuited" unless inventory_decisions.any? do |decision|
        nonboolean_decision?(decision)
      end

      "Values: Boolean T=true/F=false; flow T=selected, F=not-selected, -=skipped"
    end

    def inventory_with_default_kinds
      decisions = inventory_decisions.map do |decision|
        next decision if value(decision, :kind)

        decision.respond_to?(:key?) ? decision.merge(kind: "boolean") : decision
      end
      return @inventory unless value(@inventory, :decisions)

      @inventory.merge(decisions: decisions)
    end

    def decision_kind(decision)
      kind = value(decision, :kind).to_s
      kind.empty? ? "boolean" : kind
    end

    def nonboolean_decision?(decision)
      %w[implicit multiway pattern exception].include?(decision_kind(decision))
    end

    def decision_kind_summary_line
      counts = metrics[:kind_counts]
      return "Decision kinds: none" if counts.empty?

      contexts = metrics[:context_counts]
      suffix = if contexts.empty?
                 ""
               else
                 "; contexts: #{contexts.map do |context, count|
                   "#{context}=#{count}"
                 end.join(", ")}"
               end
      "Decision kinds: #{counts.map { |kind, count| "#{kind}=#{count}" }.join(", ")}#{suffix}"
    end

    def metrics
      @metrics ||= begin
        decisions = inventory_decisions
        unsupported, supported = decisions.partition { |decision| unsupported?(decision) }
        eligible = supported.sum { |decision| Array(value(decision, :conditions)).length }
        observed = vectors.map { |vector| value(vector, :decision_id).to_s }.uniq
        proven = @analysis ? value(@analysis, :proven_count).to_i : 0
        kind_counts = decisions.group_by { |decision| decision_kind(decision) }.transform_values(&:length)
        context_counts = decisions.group_by { |decision| value(decision, :context).to_s }
        context_counts = context_counts.reject { |context, _| context.empty? }.transform_values(&:length)
        { discovered: decisions.length, supported: supported.length, unsupported: unsupported.length,
          unsupported_conditions: unsupported.sum do |decision|
            discovered_conditions(decision)
          end, eligible_conditions: eligible,
          opaque: decisions.sum { |decision| Array(value(decision, :opaque_ranges)).length },
          unexecuted: supported.count { |decision| !observed.include?(value(decision, :id).to_s) },
          eligible_alternatives: supported.sum do |decision|
            nonboolean_decision?(decision) ? Array(value(decision, :alternatives)).length : 0
          end,
          completed: vectors.sum do |vector|
            value(vector, :count).to_i
          end, aborted: numeric_hash_value(@evidence, :abort_counts),
          unattributed: vectors.sum { |vector| value(vector, :unattributed_count).to_i }, limited: incomplete? ? 1 : 0,
          proven: proven, percentage: percentage(eligible, proven), kind_counts: kind_counts,
          decision_kinds: kind_counts, context_counts: context_counts }
      end
    end

    def completeness
      @completeness ||= begin
        evidence = value(@evidence, :completeness) || {}
        analysis = value(@analysis, :completeness) || {}
        { observation: completeness_value?(evidence, analysis, :observation),
          attribution: completeness_value?(evidence, analysis, :attribution),
          analysis: @analysis ? value(analysis, :analysis) == true : value(evidence, :analysis) == true }
      end
    end

    def completeness_value?(evidence, analysis, key)
      if (evidence.key?(key) && evidence[key] == false) || (evidence.key?(key.to_s) && evidence[key.to_s] == false)
        return false
      end
      if (analysis.key?(key) && analysis[key] == false) || (analysis.key?(key.to_s) && analysis[key.to_s] == false)
        return false
      end

      true
    end

    def valid_for_requested_level?
      return completeness[:observation] && completeness[:attribution] if @level == 1 && @analysis.nil?

      completeness.values.all? { |item| item == true }
    end

    def coverage_label
      percentage = metrics[:percentage]
      return "N/A" if percentage.nil?

      incomplete? ? "#{percentage}% (lower-bound; incomplete evidence)" : "#{percentage}%"
    end

    def analysis_status
      return "NOT_REQUESTED" if @analysis.nil?

      valid_for_requested_level? ? "COMPLETE" : "PARTIAL"
    end

    def incomplete?
      !completeness[:observation] || !completeness[:attribution] ||
        (analysis_available? && !completeness[:analysis])
    end

    def vectors_for(decision)
      vectors_by_decision_id[value(decision, :id).to_s] || []
    end

    def vectors_by_decision_id
      @vectors_by_decision_id ||= vectors.group_by { |vector| value(vector, :decision_id).to_s }
    end

    def decisions_to_render
      return inventory_decisions unless @missing_only
      return [] unless analysis_available?

      inventory_decisions
        .reject { |decision| unsupported?(decision) }
        .select do |decision|
          if nonboolean_decision?(decision)
            missing_alternatives_for(decision).any?
          else
            conditions_to_render(decision).any? || missing_decision_table_rules(decision).any?
          end
        end
    end

    def alternatives_to_render(decision)
      alternatives = Array(value(decision, :alternatives))
      return alternatives unless @missing_only && analysis_available?

      missing_ids = missing_alternatives_for(decision).map(&:to_s)
      alternatives.select { |alternative| missing_ids.include?(value(alternative, :id).to_s) }
    end

    def missing_alternatives_for(decision)
      coverage = value(value(analysis_for(decision), :coverage), :alternative)
      Array(value(coverage, :missing_alternatives))
    end

    def conditions_to_render(decision)
      conditions = Array(value(decision, :conditions))
      return conditions unless @missing_only && analysis_available?

      conditions.reject do |condition|
        value(condition_result(decision, condition), :status).to_s.upcase == "PROVEN"
      end
    end

    def vectors_to_render(decision)
      return vectors_for(decision) unless @missing_only

      []
    end

    def analysis_available?
      !@analysis.nil?
    end

    def coverage_available?
      analysis_available? && !value(@analysis, :coverage).nil?
    end

    # Render the shared ladder in every terminal view.
    def coverage_ladder_lines
      return [] unless coverage_available?

      aggregate = value(@analysis, :coverage) || {}
      rows = [["D", :decision, :covered_decisions, :supported_decisions],
              ["C", :condition, :covered_values, :required_values],
              ["C/D", :condition_decision, :covered_decisions, :supported_decisions],
              ["MC/DC", :mcdc, :proven_conditions, :supported_conditions]]
      lines = ["Coverage ladder:"]
      rows.each do |label, key, numerator_key, denominator_key|
        row = value(aggregate, key)
        next unless row

        percentage = value(row, :percentage)
        numerator = value(row, numerator_key) || 0
        denominator = value(row, denominator_key) || 0
        shown = percentage.nil? ? "N/A" : "#{percentage}%"
        denominator_label = if ["D", "C/D"].include?(label)
                              "decisions"
                            else
                              label == "C" ? "truth values" : "conditions"
                            end
        qualifier = incomplete? ? " (lower bound)" : ""
        description = case label
                      when "D" then "Decision coverage"
                      when "C" then "Condition coverage"
                      when "C/D" then "Condition/decision coverage"
                      else "MC/DC coverage"
                      end
        lines << "  #{label} (#{description}): #{shown} (#{numerator}/#{denominator} #{denominator_label})#{qualifier}"
      end
      table = value(aggregate, :decision_table)
      if table
        covered = value(table, :covered_rules) || 0
        required = value(table, :required_rules) || 0
        percentage = value(table, :percentage)
        shown = percentage.nil? ? "N/A" : "#{percentage}%"
        qualifier = incomplete? ? " (lower bound)" : ""
        lines << "  DT (Decision table coverage): #{shown} (#{covered}/#{required} rules)#{qualifier}"
        lines << "  Decision tables fully covered: #{value(table, :fully_covered_decisions) || 0}/" \
                 "#{value(table, :decisions_analyzed) || 0} decisions"
        impossible = value(table, :impossible_rules).to_i
        lines << "  Statically impossible rules excluded: #{impossible}" if impossible.positive?
        not_calculated = value(table, :not_calculated_decisions).to_i
        lines << "  Decision tables not calculated: #{not_calculated} decisions" if not_calculated.positive?
      end
      alternative = value(aggregate, :alternative)
      if alternative
        covered = value(alternative, :covered_alternatives) || 0
        required = value(alternative, :required_alternatives) || 0
        percentage = value(alternative, :percentage)
        shown = percentage.nil? ? "N/A" : "#{percentage}%"
        lines << "  Alternative coverage: #{covered}/#{required} alternatives (#{shown})"
      end
      lines << ""
      lines
    end

    def criterion_status_text(label, row)
      raw_status = value(row, :status).to_s.downcase
      status = coverage_status_label(raw_status)
      return "#{label}=#{status}" if raw_status == "unsupported"

      case label
      when "D"
        "#{label}=#{status} (#{value(row, :covered_outcomes) || 0}/#{value(row, :required_outcomes) || 0} outcomes)"
      when "C"
        "#{label}=#{status} (#{value(row, :covered_values) || 0}/#{value(row, :required_values) || 0} values; " \
        "#{value(row, :covered_conditions) || 0}/#{value(row, :condition_count) || 0} conditions fully covered)"
      when "MC/DC"
        "#{label}=#{status} (#{value(row, :proven_conditions) || 0}/#{value(row, :condition_count) || 0} conditions)"
      when "DT"
        return "#{label}=NOT CALCULATED (#{value(row, :reason)})" if raw_status == "not_calculated"

        "#{label}=#{status} (#{value(row, :covered_rules) || 0}/#{value(row, :required_rules) || 0} rules)"
      else
        "#{label}=#{status}"
      end
    end

    def analysis_complete?
      analysis_available? && baseline_status == "PASSED" && completeness.values.all?
    end

    def missing_condition_count
      decisions_to_render.sum { |decision| conditions_to_render(decision).length }
    end

    def missing_summary_line
      return "Missing conditions: Cannot identify missing conditions (analysis unavailable)" unless analysis_available?
      return "Missing conditions: Cannot identify missing conditions (analysis incomplete)" unless analysis_complete?
      if missing_condition_count.zero? && missing_alternatives_count.zero? && missing_rule_count.zero?
        return "No missing conditions, alternatives, or decision-table rules"
      end
      return "No eligible conditions" if metrics[:eligible_conditions].zero? && metrics[:eligible_alternatives].zero?

      count = decisions_to_render.length
      label = count == 1 ? "decision" : "decisions"
      suffix = missing_rule_count.positive? ? "; decision-table rules: #{missing_rule_count}" : ""
      if missing_condition_count.zero? && missing_alternatives_count.zero?
        return "Missing decision-table rules: #{missing_rule_count} across #{count} #{label}"
      end
      if missing_alternatives_count.zero?
        return "Missing conditions: #{missing_condition_count} across #{count} #{label}#{suffix}"
      end
      if missing_condition_count.zero?
        return "Missing alternatives: #{missing_alternatives_count} across #{count} #{label}#{suffix}"
      end

      conditions = missing_condition_count
      alternatives = missing_alternatives_count
      "Missing conditions: #{conditions}; alternatives: #{alternatives} " \
        "across #{count} #{label}#{suffix}"
    end

    def missing_rule_count
      decisions_to_render.sum { |decision| missing_decision_table_rules(decision).length }
    end

    def missing_alternatives_count
      decisions_to_render.sum { |decision| missing_alternatives_for(decision).length }
    end

    def analysis_for(decision)
      analysis_by_decision_id[value(decision, :id).to_s]
    end

    def analysis_by_decision_id
      @analysis_by_decision_id ||= Array(value(@analysis, :decisions)).to_h do |item|
        [value(item, :decision_id).to_s, item]
      end
    end

    def source_for(decision)
      source_by_source_id[value(decision, :source_id).to_s] || decision
    end

    def source_by_source_id
      @source_by_source_id ||= Array(value(@inventory, :source_units)).to_h do |source|
        [value(source, :source_id).to_s, source]
      end
    end

    def inventory_decisions = Array(value(@inventory, :decisions))
    def vectors = Array(value(@evidence, :vectors))
    def unsupported?(decision) = value(decision, :support_status).to_s.upcase == "UNSUPPORTED"

    def discovered_conditions(decision)
      value(decision,
            :discovered_condition_count) || Array(value(decision,
                                                        :conditions)).length
    end

    def percentage(denominator, numerator) = denominator.zero? ? nil : (numerator.to_f * 100 / denominator).round(2)

    def numeric_hash_value(hash, key)
      item = value(hash, key)
      item.is_a?(Hash) ? item.values.sum(&:to_i) : item.to_i
    end

    def usage_valid?
      @diagnostics.none? do |diagnostic|
        %w[usage invalid_option].include?(value(diagnostic, :code).to_s)
      end
    end

    def value(hash, key)
      return nil unless hash.respond_to?(:key?)
      return hash[key] if hash.key?(key)
      return hash[key.to_s] if hash.key?(key.to_s)

      nil
    end

    def normalize(object)
      case object
      when Hash
        object.each_with_object({}) do |(key, item), result|
          result[key.to_s] = normalize(item) unless key.to_s == "original_bytes"
        end
      when Array then object.map { |item| normalize(item) }
      when Symbol then object.to_s
      when Numeric, String, TrueClass, FalseClass, NilClass then object
      else normalize_unknown(object)
      end
    end

    def normalize_unknown(object)
      object.to_s
    end
    public :condition_coverage_evidence, :coverage_ladder_lines, :coverage_status_label
  end
end

# rubocop:enable Metrics/BlockLength
