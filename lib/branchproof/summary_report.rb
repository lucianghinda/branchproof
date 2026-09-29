# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
require_relative "summary_ranking"

module Branchproof
  # Terminal view that lists the largest coverage gaps first.
  class SummaryReport
    RULE_LABELS = { "true" => "T", "false" => "F", "dont_care" => "-" }.freeze
    ORDER_NOTE = "Order: unexecuted decisions first, then most missing obligations " \
                 "(decision-table rules, unproven MC/DC conditions, missing alternatives); " \
                 "a count, not a risk estimate."
    SHOWN_TESTS = 3
    EXPRESSION_WIDTH = 100

    class << self
      # Shared wording for terminal rows and GitHub output.
      def gap_summary(decision)
        parts = []
        parts << "unexecuted" if decision.unexecuted
        if decision.table_calculated
          parts << "DT #{decision.missing_rules.length}/#{decision.required_rules} rules missing"
        end
        unless decision.conditions.empty?
          parts << "MC/DC #{decision.unproven_conditions.length}/#{decision.conditions.length} conditions unproven"
        end
        unless decision.alternatives.empty?
          parts << "#{decision.missing_alternatives.length}/#{decision.alternatives.length} alternatives missing"
        end
        parts.join("; ")
      end

      # One line per missing case: decision-table rules when some are missing,
      # otherwise unproven conditions; then missing alternatives.
      def case_lines(decision, coordinator)
        lines = []
        if decision.rule_cases?
          expressions = decision.conditions.sort_by { |row| row[:index].to_i }.map { |row| row[:expression] }
          heading = coordinator.decision_table_expected_heading({ context: decision.context })
          decision.missing_rules.each do |rule|
            lines << "#{rule_text(rule, expressions, coordinator)}; " \
                     "#{heading.downcase.delete_suffix(":")} #{rule[:outcome] ? "true" : "false"}"
          end
        else
          decision.unproven_conditions.each do |row|
            explanation = coordinator.condition_explanation(decision_id: decision.id, condition_id: row[:id])
            lines << "Condition #{row[:index]}: #{row[:expression]} NOT_PROVEN#{explanation}"
          end
        end
        decision.missing_alternatives.each { |row| lines << "Need selection of: #{row[:expression]}" }
        lines
      end

      def one_line(text, width = EXPRESSION_WIDTH)
        text = text.to_s.gsub(/\s+/, " ").strip
        text.length > width ? "#{text[0, width - 3]}..." : text
      end

      def rule_text(rule, expressions, coordinator)
        signature = Array(rule[:conditions]).map { |item| RULE_LABELS.fetch(item.to_s, item.to_s) }.join
        requirements = Array(rule[:conditions]).each_with_index.filter_map do |item, index|
          requirement = coordinator.decision_table_requirement(item)
          "#{expressions[index] || "condition #{index}"} #{requirement}" if requirement
        end
        "#{rule[:label]} [#{signature}]: #{requirements.join(", ")}"
      end
    end

    def initialize(document:, level:, coordinator:, missing_only: false, selection: ReportSelection.new)
      @document = document || {}
      @level = level.to_i
      @coordinator = coordinator
      @missing_only = missing_only ? true : false
      @selection = selection
      @ranking = SummaryRanking.new(document: @document, selection: selection)
      @tests = @ranking.index.tests.to_h { |test| [test[:id].to_s, test] }
    end

    def render
      baseline = fetch(@document, :baseline) || {}
      completeness = fetch(@document, :completeness) || {}
      lines = ["Branchproof summary view", "Tests: #{fetch(baseline, :status) || "INCOMPLETE"}"]
      if completeness.values.include?(false) || fetch(baseline, :status).to_s != "PASSED"
        lines << "Warning: failed or incomplete run; counts are lower bounds."
      end
      lines << ""
      render_focus_notice(lines)
      lines.concat(@coordinator.coverage_ladder_lines)
      lines.concat(@coordinator.coverage_policy_lines)
      if @ranking.available?
        render_ranking(lines)
      else
        lines << "Ranking unavailable: the report has no analysis."
      end
      unsupported = @ranking.unsupported_count
      if unsupported.positive?
        lines << "Unsupported decisions: #{unsupported} (not ranked; MC/DC unavailable) (run-wide)"
      end
      Array(fetch(@document, :diagnostics)).each do |diagnostic|
        lines << "Diagnostic: #{@coordinator.diagnostic_message(diagnostic)}"
      end
      lines.join("\n") << "\n"
    end

    private

    def render_ranking(lines)
      lines << ORDER_NOTE
      lines << ""
      files = @ranking.files
      files = files.select { |file| file.gaps.positive? } if @missing_only
      files, hidden_files = @selection.limit(files)
      gaps, hidden_gaps = @selection.limit(@ranking.gaps)
      if @selection.top
        lines << "Display limit: top #{@selection.top} per list; " \
                 "hidden #{hidden_files} #{hidden_files == 1 ? "file" : "files"}, " \
                 "#{hidden_gaps} #{hidden_gaps == 1 ? "decision" : "decisions"}"
        lines << ""
      end
      render_files(lines, files)
      render_gaps(lines, gaps)
    end

    def render_files(lines, files)
      lines << "Files:"
      lines << "  none" if files.empty?
      files.each_with_index do |file, position|
        parts = ["#{file.gaps}/#{file.decisions.length} decisions with gaps"]
        parts << "#{file.unexecuted} unexecuted" if file.unexecuted.positive?
        parts << "DT #{file.missing_rules}/#{file.required_rules} rules missing" if file.required_rules.positive?
        parts << "MC/DC #{file.unproven_conditions}/#{file.conditions} conditions unproven" if file.conditions.positive?
        parts << "#{file.missing_alternatives}/#{file.alternatives} alternatives missing" if file.alternatives.positive?
        lines << "  #{position + 1}. #{file.relative_path || "location unavailable"}: #{parts.join("; ")}"
      end
      lines << ""
    end

    def render_gaps(lines, gaps)
      lines << "Where to start:"
      if gaps.empty?
        lines << (focus_match? ? "  No missing coverage" : "  none")
        lines << ""
        return
      end
      gaps.each_with_index do |decision, position|
        lines << "  #{position + 1}. #{location(decision)}  #{self.class.one_line(decision.expression)}"
        lines << "     #{self.class.gap_summary(decision)}"
        if @level >= 2
          lines << "     Cases to test: #{decision.cases_to_test}"
          self.class.case_lines(decision, @coordinator).each { |line| lines << "     #{line}" }
        end
        render_reaching_tests(lines, decision) if @level >= 3
        lines << ""
      end
    end

    def render_reaching_tests(lines, decision)
      ids = decision.test_ids
      if ids.empty?
        lines << "     Tests reaching this decision: none recorded"
        return
      end
      lines << "     Tests reaching this decision:"
      ids.map { |id| test_label(id) }.sort.first(SHOWN_TESTS).each { |label| lines << "       #{label}" }
      lines << "       #{ids.length - SHOWN_TESTS} more" if ids.length > SHOWN_TESTS
    end

    def render_focus_notice(lines)
      return unless @selection.focus_active?

      label = @selection.focus_label
      lines << (focus_match? ? "Focus: #{label}" : "Focus: no matching decisions for #{label}")
    end

    def focus_match?
      !@selection.focus_active? || !@selection.matching_decision_ids(@document).empty?
    end

    def location(decision)
      return "location unavailable" if decision.relative_path.nil?

      decision.line ? "#{decision.relative_path}:#{decision.line}" : decision.relative_path
    end

    def test_label(id)
      test = @tests[id.to_s]
      return id.to_s unless test

      label = test[:name].to_s
      label += " (#{test[:relative_path]}:#{test[:line]})" if test[:relative_path] && test[:line]
      command = @coordinator.rerun_command(id)
      command ? "#{label} (rerun: #{command})" : label
    end

    def fetch(hash, key)
      return nil unless hash.respond_to?(:key?)

      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
