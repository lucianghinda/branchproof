# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
require_relative "summary_report"

module Branchproof
  # GitHub Actions output: workflow-command annotations for the ranked gaps and
  # a Markdown job summary. Both reuse the summary view's ranking and wording.
  class GithubReport
    MARKDOWN_ROWS = 20

    # path_prefix maps project-relative paths to repository-relative ones
    # when the project is not at the repository root.
    def initialize(document:, level:, coordinator:, selection: ReportSelection.new, path_prefix: nil)
      @document = document || {}
      @path_prefix = path_prefix
      @level = level.to_i
      @coordinator = coordinator
      @selection = selection
      @ranking = SummaryRanking.new(document: @document, selection: selection)
    end

    # Workflow commands for stdout, one warning per ranked decision gap.
    def annotations(path_prefix: @path_prefix)
      path_prefix = path_prefix.to_s.empty? ? nil : path_prefix.to_s.delete_suffix("/")
      lines = error_lines
      if @coordinator.collation_lines.any?
        status = fetch(fetch(@document, :collation), :collection_status)
        lines << command("notice", @coordinator.collation_lines.join("\n"),
                         title: "Branchproof collation: #{status}")
      end
      lines << command("notice", changed_scope_message, title: "Branchproof changed scope") if changed_scope?
      gaps, hidden = @selection.limit(ranked_gaps)
      gaps.each_with_index do |decision, position|
        lines << command("warning", annotation_message(decision),
                         title: "Branchproof ##{position + 1}: #{SummaryReport.gap_summary(decision)}",
                         file: annotation_path(decision.relative_path, path_prefix), line: decision.line)
      end
      lines << command("notice", notice_message(hidden), title: "Branchproof coverage")
      lines.join("\n") << "\n"
    end

    # Markdown for $GITHUB_STEP_SUMMARY.
    def step_summary
      status = fetch(fetch(@document, :baseline) || {}, :status) || "INCOMPLETE"
      lines = ["## Branchproof coverage", "", "**Tests:** #{status}", ""]
      if changed_scope?
        focus_notice = changed_focus_notice
        lines << focus_notice if focus_notice
        lines << "**Whole-run coverage and policy**"
        lines << ""
      end
      ladder = ladder_lines
      unless ladder.empty?
        lines.concat(ladder.map { |line| "- #{line}" })
        lines << ""
      end
      if changed_scope?
        lines.concat(@coordinator.changed_scope_lines.map { |line| "- #{code(line)}" })
        lines << ""
      end
      collation = @coordinator.collation_lines
      unless collation.empty?
        lines.concat(collation.map { |line| "- #{code(line.strip)}" })
        lines << ""
      end
      render_diagnostics(lines)
      render_policy(lines)
      render_gap_table(lines)
      lines.join("\n") << "\n"
    end

    private

    def changed_scope?
      !fetch(@document, :changed_scope).nil?
    end

    def changed_scope_message
      @coordinator.changed_scope_lines.join("\n")
    end

    def changed_scope_focus_empty?
      changed_scope? && @selection.focus_active? && @selection.selected_decision_ids(@document).empty?
    end

    def changed_focus_notice
      return unless changed_scope? && @selection.focus_active?

      if changed_scope_focus_empty?
        "**Focus:** no matching changed decisions for #{code(@selection.focus_label)}"
      else
        "**Focus:** #{code(@selection.focus_label)}"
      end
    end

    # Every non-zero exit status gets at least one error that names a reason.
    def error_lines
      lines = []
      baseline = fetch(@document, :baseline) || {}
      status = (fetch(baseline, :status) || "INCOMPLETE").to_s
      if status != "PASSED"
        lines << command("error", "Tests #{status}", title: "Branchproof tests")
      elsif fetch(baseline, :finalized) != true || (fetch(@document, :completeness) || {}).values.include?(false)
        lines << command("error", "Run incomplete; coverage counts are lower bounds", title: "Branchproof run")
      end
      unmet_gates.each do |gate|
        lines << command("error", gate_text(gate), title: "Branchproof coverage policy")
      end
      exit_code = @coordinator.exit_code
      if lines.empty? && exit_code.positive?
        lines << command("error", "Exit status #{exit_code}; see the terminal report diagnostics", title: "Branchproof")
      end
      diagnostics.each do |diagnostic|
        diagnostic_code = fetch(diagnostic, :code).to_s
        lines << command(annotation_severity(diagnostic), @coordinator.diagnostic_message(diagnostic),
                         title: "Branchproof diagnostic (#{diagnostic_code})")
      end
      lines
    end

    def diagnostics
      Array(fetch(@document, :diagnostics))
    end

    def diagnostic_severity(diagnostic)
      fetch(diagnostic, :severity).to_s.downcase
    end

    def annotation_severity(diagnostic)
      severity = diagnostic_severity(diagnostic)
      %w[error warning].include?(severity) ? severity : "notice"
    end

    def render_diagnostics(lines)
      details = diagnostics
      return if details.empty?

      lines << "### Diagnostics"
      lines << ""
      details.each do |diagnostic|
        severity = diagnostic_severity(diagnostic).upcase
        diagnostic_code = fetch(diagnostic, :code).to_s
        message = @coordinator.diagnostic_message(diagnostic)
        lines << "- **#{severity} (#{diagnostic_code}):** #{code(message)}"
      end
      lines << ""
    end

    def annotation_path(path, path_prefix)
      return nil if path.nil?

      path_prefix ? "#{path_prefix}/#{path}" : path
    end

    def ranked_gaps
      @ranking.available? ? @ranking.gaps : []
    end

    def annotation_message(decision)
      lines = [SummaryReport.one_line(decision.expression)]
      if @level >= 2
        lines << "Cases to test: #{decision.cases_to_test}"
        lines.concat(SummaryReport.case_lines(decision, @coordinator))
      end
      lines.join("\n")
    end

    def notice_message(hidden)
      lines = ladder_lines
      lines = ["Coverage ladder unavailable"] if lines.empty?
      focus_notice = changed_focus_notice
      lines.unshift(focus_notice) if focus_notice
      lines.unshift("Whole-run coverage and policy:") if changed_scope?
      lines.concat(@coordinator.changed_scope_lines) if changed_scope?
      lines << if @ranking.available?
                 "Decisions with gaps: #{ranked_gaps.length}"
               else
                 "Ranking unavailable: the report has no analysis"
               end
      lines << "Not annotated (--top): #{hidden}" if hidden.positive?
      if @ranking.unsupported_count.positive?
        lines << "Unsupported decisions: #{@ranking.unsupported_count} (not ranked)"
      end
      lines.join("\n")
    end

    def render_policy(lines)
      policy = @coordinator.coverage_policy
      return if (fetch(policy, :minimum) || {}).empty?

      lines << "**Coverage policy:** #{fetch(policy, :status).to_s.upcase}"
      lines << ""
      lines << "| Criterion | Covered | Threshold | Status | Reason |"
      lines << "| --- | --- | ---: | --- | --- |"
      Array(fetch(policy, :gates)).each do |gate|
        lines << "| #{cell(fetch(gate, :criterion))} | #{gate_count(gate)} | #{fetch(gate, :minimum)} | " \
                 "#{fetch(gate, :status).to_s.upcase} | #{cell(fetch(gate, :reason))} |"
      end
      lines << ""
    end

    def render_gap_table(lines)
      lines << "### Where to start"
      lines << ""
      unless @ranking.available?
        lines << "Ranking unavailable: the report has no analysis."
        return
      end
      gaps = ranked_gaps
      if gaps.empty?
        lines << if changed_scope? && (changed_scope_focus_empty? || !@coordinator.changed_coverage_available?)
                   "Changed-scope gaps are unavailable from the captured evidence."
                 else
                   (changed_scope? ? "No changed-scope gaps found." : "No missing coverage.")
                 end
        return
      end
      limit = @selection.top || MARKDOWN_ROWS
      lines << SummaryReport::ORDER_NOTE
      lines << ""
      lines << "| # | Location | Decision | Gaps | Cases to test |"
      lines << "| ---: | --- | --- | --- | ---: |"
      gaps.first(limit).each_with_index do |decision, position|
        lines << "| #{position + 1} | #{code(location(decision))} | #{code(SummaryReport.one_line(decision.expression,
                                                                                                  80))} | " \
                 "#{cell(SummaryReport.gap_summary(decision))} | #{decision.cases_to_test} |"
      end
      hidden = gaps.length - limit
      lines << "" << "#{hidden} more #{hidden == 1 ? "decision" : "decisions"} with gaps not shown." if hidden.positive?
    end

    def ladder_lines
      @coordinator.coverage_ladder_lines.map(&:strip).reject { |line| line.empty? || line == "Coverage ladder:" }
    end

    def unmet_gates
      Array(fetch(@coordinator.coverage_policy, :gates)).reject { |gate| fetch(gate, :status).to_s == "passed" }
    end

    def gate_text(gate)
      text = "#{fetch(gate, :criterion)}: #{gate_count(gate)}, threshold #{fetch(gate, :minimum)}"
      status = fetch(gate, :status).to_s
      text += ", #{status}" unless status == "failed"
      reason = fetch(gate, :reason)
      reason ? "#{text}; reason: #{reason}" : text
    end

    def gate_count(gate)
      denominator = fetch(gate, :denominator)
      return "N/A" if denominator.nil? || denominator.to_i.zero?

      "#{fetch(gate, :numerator) || "N/A"}/#{denominator}"
    end

    def location(decision)
      return "location unavailable" if decision.relative_path.nil?

      decision.line ? "#{decision.relative_path}:#{decision.line}" : decision.relative_path
    end

    def command(kind, message, title:, file: nil, line: nil)
      properties = []
      properties << "file=#{property(file)}" if file
      properties << "line=#{line.to_i}" if file && line
      properties << "title=#{property(title)}"
      "::#{kind} #{properties.join(",")}::#{data(message)}"
    end

    # Escaping rules from the GitHub Actions workflow command toolkit.
    def data(text) = text.to_s.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
    def property(text) = data(text).gsub(":", "%3A").gsub(",", "%2C")

    # The fence must be longer than any backtick run inside the text.
    def code(text)
      text = cell(text)
      longest = text.scan(/`+/).map(&:length).max || 0
      fence = "`" * (longest + 1)
      padding = longest.positive? ? " " : ""
      "#{fence}#{padding}#{text}#{padding}#{fence}"
    end

    def cell(text) = text.to_s.gsub(/\s+/, " ").gsub("|", "\\|")

    def fetch(hash, key)
      return nil unless hash.respond_to?(:key?)

      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
