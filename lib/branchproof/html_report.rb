# frozen_string_literal: true

require "erb"
require_relative "summary_ranking"
require_relative "summary_report"

module Branchproof
  # Portable, offline HTML presentation of a saved report document.
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  class HtmlReport
    # Keep complete HTML fragments together so their semantic structure is visible.
    # rubocop:disable Layout/LineLength
    STYLE = <<~CSS
      :root{color-scheme:light;--paper:#f5f2e9;--ink:#202d2c;--muted:#566967;--teal:#116b66;--line:#c9d3cd;--amber:#8a4b08;--panel:#fffdf7;--soft:#e7eee9}
      *{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif;overflow-wrap:anywhere}
      a{color:var(--teal);text-underline-offset:.18em}a:focus-visible,summary:focus-visible{outline:3px solid #bd741d;outline-offset:3px}
      .skip{position:absolute;left:-9999px;top:0;background:var(--panel);padding:.6rem}.skip:focus{left:1rem;z-index:2}
      header,.layout,footer{max-width:1280px;margin:auto;padding:1.4rem 1.5rem}header{border-bottom:1px solid var(--line)}h1,h2,h3{font-family:Georgia,"Times New Roman",serif;line-height:1.2}h1{font-size:2.2rem;margin:.2rem 0}h2{font-size:1.55rem;margin:0 0 .7rem}h3{font-size:1.15rem;margin:.4rem 0}
      .eyebrow,.status,.meta{color:var(--muted);font-size:.9rem}.warning,.gap{color:var(--amber)}.warning{font-weight:700}.layout{display:grid;grid-template-columns:minmax(14rem,18rem) minmax(0,1fr);gap:2rem;align-items:start}
      nav{position:sticky;top:1rem;border-right:1px solid var(--line);padding-right:1rem}nav ul{list-style:none;padding:0;margin:.5rem 0}nav li{padding:.55rem 0;border-bottom:1px solid var(--line)}nav a{font-weight:650}nav small{display:block;color:var(--muted);font-weight:400}
      main{min-width:0}section{margin:0 0 2rem}.overview,.decision{background:var(--panel);border:1px solid var(--line);padding:1rem 1.2rem;margin:0 0 1rem}.decision{border-top:3px solid var(--teal);scroll-margin-top:1rem}.decision.has-gap{border-top-color:#bd741d}
      .expression,pre,code,.mono{font-family:ui-monospace,SFMono-Regular,Consolas,monospace}.expression{white-space:pre-wrap;overflow-wrap:anywhere;background:var(--soft);padding:.75rem;border-radius:2px}.meta{display:flex;gap:.5rem 1rem;flex-wrap:wrap}.badge{display:inline-block;border:1px solid var(--line);border-radius:2px;padding:.08rem .4rem;font-size:.82rem}
      table{border-collapse:collapse;width:100%;min-width:34rem}th,td{text-align:left;vertical-align:top;padding:.45rem .6rem;border-bottom:1px solid var(--line)}th{background:var(--soft)}.table-wrap{max-width:100%;overflow-x:auto;margin:.7rem 0}.table-wrap:focus-visible{outline:3px solid #bd741d;outline-offset:3px}
      details{margin:.5rem 0}summary{cursor:pointer;font-weight:650}ul.evidence{padding-left:1.3rem}footer{border-top:1px solid var(--line);color:var(--muted);font-size:.9rem}
      @media(max-width:760px){.layout{display:block;padding-top:1rem}nav{position:static;border:0;border-bottom:1px solid var(--line);padding:0 0 1rem;margin-bottom:1.5rem}nav ul{display:grid;grid-template-columns:repeat(auto-fit,minmax(10rem,1fr));gap:0 1rem}header,.layout,footer{padding-left:1rem;padding-right:1rem}}
      @media print{body{background:white;color:black;font-size:11pt}.layout{display:block;max-width:none}nav{position:static;border:1px solid #aaa;break-after:avoid}a{color:inherit;text-decoration:none}.overview,.decision{background:white;border-color:#aaa;break-inside:avoid}details>*{display:block!important}.table-wrap{overflow:visible}table{min-width:0}header,.layout,footer{max-width:none;padding:.5rem}}
    CSS

    def initialize(document:, level:, coordinator:, missing_only: false, selection: ReportSelection.new)
      @document = document || {}
      @level = level.to_i
      @coordinator = coordinator
      @missing_only = missing_only ? true : false
      @selection = selection
      @ranking = SummaryRanking.new(document: @document, selection: selection)
      @index = @ranking.index
      @conditions = @index.conditions.group_by { |row| row[:decision_id].to_s }
      @alternatives = @index.alternatives.group_by { |row| row[:decision_id].to_s }
      @tables = @index.decision_tables.to_h { |row| [row[:decision_id].to_s, row] }
      @tests = @index.tests.to_h { |row| [row[:id].to_s, row] }
    end

    def render
      out = String.new
      out << "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
      out << "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
      out << "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\">"
      out << "<title>Branchproof report</title><style>#{STYLE}</style></head><body>"
      out << "<a class=\"skip\" href=\"#report-content\">Skip to report</a>"
      out << header_html
      out << "<div class=\"layout\">#{navigation_html}<main id=\"report-content\">"
      out << overview_html
      out << changed_scope_html
      out << decisions_html
      out << diagnostics_html
      out << "</main></div><footer>Generated from the saved Branchproof snapshot. This document works offline.</footer></body></html>\n"
      out
    end

    private

    def header_html
      baseline = fetch(@document, :baseline) || {}
      status = fetch(baseline, :status) || "INCOMPLETE"
      completeness = fetch(@document, :completeness) || {}
      incomplete = completeness.values.include?(false) || status.to_s != "PASSED" || fetch(baseline,
                                                                                           :finalized) == false
      out = +"<header><div class=\"eyebrow\">Branchproof saved report</div><h1>Coverage report</h1>"
      out << "<p class=\"meta\"><span>Tests: <strong>#{escape(status)}</strong></span>"
      out << "<span>Analysis: <strong>#{@ranking.available? ? "available" : "unavailable"}</strong></span></p>"
      out << "<p class=\"warning\">Failed or incomplete run; counts are lower bounds.</p>" if incomplete
      out << "</header>"
    end

    def navigation_html
      entries = visible_decisions
      ordinals = {}.compare_by_identity
      entries.each_with_index { |decision, index| ordinals[decision] = index + 1 }
      file_order = @ranking.files.each_with_index.to_h { |file, index| [file.relative_path, index] }
      files = entries.group_by(&:relative_path).sort_by { |path, _rows| file_order.fetch(path, Float::INFINITY) }
      out = +"<nav aria-label=\"Source files\"><h2>Files</h2>"
      if files.empty?
        out << "<p class=\"status\">No decisions in this selection.</p>"
      else
        out << "<ul>"
        files.each do |path, rows|
          first = ordinals.fetch(rows.first)
          gaps = rows.count(&:gap?)
          out << "<li><a href=\"#decision-#{first}\">#{escape(path || "location unavailable")}</a>"
          out << "<small>#{gaps}/#{rows.length} decisions with known gaps</small></li>"
        end
        out << "</ul>"
      end
      out << "</nav>"
    end

    def overview_html
      lines = @coordinator.coverage_ladder_lines
      out = +"<section class=\"overview\" aria-labelledby=\"overview-title\"><h2 id=\"overview-title\">Whole-run coverage and policy</h2>"
      if @selection.focus_active?
        label = @selection.focus_label
        out << "<p>Focus: #{escape(label)}</p>"
      end
      if @selection.decision_ids == []
        out << "<p class=\"warning\">An empty decision selection does not establish full coverage.</p>"
      end
      if @selection.decision_ids == []
        out << "<p>Decision selection: 0 decisions. Coverage is <strong>not established</strong>.</p>"
      end
      coverage_lines = lines.reject { |line| line.strip.empty? || line.strip == "Coverage ladder:" }
      coverage_items = coverage_lines.map { |line| "<li>#{escape(line.strip)}</li>" }.join
      coverage_html = if lines.empty?
                        "<p class=\"status\">Coverage analysis unavailable; coverage is N/A.</p>"
                      else
                        "<ul>#{coverage_items}</ul>"
                      end
      out << coverage_html
      policy_lines = @coordinator.coverage_policy_lines
      unless policy_lines.empty?
        out << "<h3>Whole-run coverage policy</h3><ul>"
        policy_lines.reject { |line| line.strip.empty? }.each { |line| out << "<li>#{escape(line.strip)}</li>" }
        out << "</ul>"
      end
      if @ranking.available?
        out << "<p>#{@ranking.decisions.length} supported decisions in this selection; #{@ranking.gaps.length} with known gaps.</p>"
      else
        out << "<p>Analysis unavailable. Source inventory remains available; no missing scenarios are inferred.</p>"
      end
      if @selection.top && hidden_decision_count.positive?
        noun = @ranking.available? ? "ranked decisions" : "inventory decisions"
        out << "<p>Display limit: top #{@selection.top}; #{hidden_decision_count} #{noun} hidden.</p>"
      end
      unsupported = @ranking.unsupported_count
      out << "<p>Unsupported decisions: #{unsupported} (not ranked; MC/DC unavailable) (run-wide).</p>" if unsupported.positive?
      out << "</section>"
    end

    def changed_scope_html
      return "" unless fetch(@document, :changed_scope)

      lines = @coordinator.changed_scope_lines
      return "" if lines.empty?

      out = +"<section class=\"overview\" aria-labelledby=\"changed-title\"><h2 id=\"changed-title\">Captured changed scope</h2>"
      out << "<p>Changed-scope ranking is informational. Whole-run policy above remains global.</p><ul>"
      lines.each { |line| out << "<li>#{escape(line.strip)}</li>" unless line.strip.empty? }
      out << "</ul></section>"
    end

    def decisions_html
      return inventory_html unless @ranking.available?

      entries = visible_decisions
      out = +"<section aria-labelledby=\"decisions-title\"><h2 id=\"decisions-title\">Ranked decisions</h2>"
      if entries.empty?
        message = if @selection.decision_ids == []
                    "No decisions are selected; full coverage is not established."
                  elsif @selection.focus_active? || @selection.decision_ids
                    "No decisions match this selection."
                  else
                    "No decisions are available."
                  end
        out << "<p class=\"status\">#{escape(message)}</p>"
        return out << "</section>"
      end
      entries.each_with_index { |decision, position| out << decision_html(decision, position + 1) }
      out << "</section>"
    end

    def inventory_html
      inventory = fetch(@document, :source_inventory) || fetch(@document, :inventory) || {}
      sources = Array(fetch(inventory, :source_units)).to_h do |source|
        [fetch(source, :source_id).to_s, fetch(source, :relative_path)]
      end
      decisions = shown_inventory_decisions
      out = +"<section aria-labelledby=\"inventory-title\"><h2 id=\"inventory-title\">Source inventory</h2>"
      if decisions.empty?
        out << "<p>Analysis unavailable. No decisions were inventoried.</p>"
      else
        out << "<ul>"
        decisions.each do |decision|
          path = sources[fetch(decision, :source_id).to_s]
          out << "<li>#{escape(path || "location unavailable")} — <code>#{escape(fetch(decision,
                                                                                       :expression))}</code>; analysis unavailable</li>"
        end
        out << "</ul>"
      end
      out << "</section>"
    end

    def decision_html(decision, ordinal)
      gap = decision.gap?
      location = if decision.relative_path
                   [decision.relative_path,
                    decision.line].compact.join(":")
                 else
                   "location unavailable"
                 end
      out = "<article class=\"decision#{" has-gap" if gap}\" id=\"decision-#{ordinal}\"><h3>Decision #{ordinal}: #{escape(location)}</h3>"
      out << "<div class=\"expression\">#{escape(decision.expression)}</div><p class=\"meta\">"
      out << "<span>#{escape(decision.kind)}</span><span>#{gap ? "Known gap" : "No known gap"}</span>"
      out << "<span>#{escape(SummaryReport.gap_summary(decision))}</span></p>"
      out << "<p>Cases to test: #{decision.cases_to_test}</p>" if @level >= 2
      out << missing_scenarios(decision) if @level >= 2
      out << condition_details(decision, ordinal) if @level >= 2
      out << table_details(decision, ordinal) if @level >= 2
      out << alternative_details(decision) if @level >= 2
      out << contributing_tests(decision) if @level >= 3
      out << "</article>"
    end

    def condition_details(decision, ordinal)
      rows = @conditions.fetch(decision.id, [])
      return "" if rows.empty?

      out = +"<h3>Conditions and MC/DC evidence</h3>"
      out << "<div class=\"table-wrap\" tabindex=\"0\" role=\"region\" aria-label=\"Decision #{ordinal} condition evidence\">"
      out << "<table><thead><tr><th scope=\"col\">Condition</th><th scope=\"col\">Status</th>"
      out << "<th scope=\"col\">Evidence</th></tr></thead><tbody>"
      rows.each do |row|
        status = row[:status].to_s
        owners = Array(row[:witness_owner_details])
        details = []
        true_tests = test_labels(row[:observed_true])
        false_tests = test_labels(row[:observed_false])
        short_circuited_tests = test_labels(row[:short_circuited])
        if @level >= 3
          details << "true observed by #{true_tests.join(", ")}" unless true_tests.empty?
          details << "false observed by #{false_tests.join(", ")}" unless false_tests.empty?
          details << "short-circuited by #{short_circuited_tests.join(", ")}" unless short_circuited_tests.empty?
          details << (owners.empty? ? "Proof owner: none recorded" : "Proof owner: #{owners.join(", ")}")
        else
          details << "true observed: #{true_tests.empty? ? "no" : "yes"}"
          details << "false observed: #{false_tests.empty? ? "no" : "yes"}"
          details << "short-circuited: #{short_circuited_tests.empty? ? "no" : "yes"}"
        end
        out << "<tr><th scope=\"row\"><code>#{escape(row[:expression])}</code></th><td>#{escape(status)}</td><td>#{escape(details.join("; "))}</td></tr>"
      end
      out << "</tbody></table></div>"
    end

    def missing_scenarios(decision)
      cases = SummaryReport.case_lines(decision, @coordinator)
      return "<p>No missing scenarios are known.</p>" if cases.empty? && !decision.unexecuted

      out = +"<h3>Missing scenarios</h3><ul>"
      cases.each { |item| out << "<li><code>#{escape(item)}</code></li>" }
      out << "<li>No observed execution for this decision.</li>" if decision.unexecuted
      out << "</ul>"
    end

    def table_details(decision, ordinal)
      table = @tables[decision.id]
      unless decision.table_calculated
        table = @tables[decision.id]
        status = table && table[:status]
        reason = table && table[:reason]
        message = status.to_s.empty? ? "Decision table: not calculated." : "Decision table: #{status}."
        message += " Reason: #{reason}." if reason
        return "<p>#{escape(message)}</p>"
      end
      return "" unless table

      excluded = table[:impossible_rules].to_i
      reachability = table_reachability_status(table)
      out = "<h3>Decision-table rules</h3><p>Required denominator: #{decision.required_rules} rules. "
      out << "Excluded: #{excluded} impossible rules. Reachability analysis: #{reachability}."
      out << " #{table[:generated_rules]} generated rules recorded." if table[:generated_rules]
      out << "</p><div class=\"table-wrap\" tabindex=\"0\" role=\"region\" aria-label=\"Decision #{ordinal} decision-table rules\">"
      out << "<table><thead><tr><th scope=\"col\">Rule</th><th scope=\"col\">Requirements</th>"
      out << "<th scope=\"col\">Expected result</th><th scope=\"col\">Coverage</th>"
      out << "<th scope=\"col\">Reachability</th><th scope=\"col\">Reason</th></tr></thead><tbody>"
      table[:rules].each do |rule|
        expressions = decision.conditions.sort_by { |row| row[:index].to_i }.map { |row| row[:expression] }
        status = fetch(rule, :coverage).to_s
        label = fetch(rule, :label)
        requirements = SummaryReport.rule_text(rule, expressions, @coordinator).sub(/\A[^:]+:\s*/, "")
        outcome = fetch(rule, :outcome) ? "true" : "false"
        rule_reachability = rule_reachability_status(rule)
        reason = reachability_reason(rule)
        out << "<tr><th scope=\"row\">#{escape(label)}</th><td>#{escape(requirements)}</td>"
        out << "<td>#{outcome}</td><td>#{escape(status)}</td>"
        out << "<td>#{escape(rule_reachability)}</td><td>#{escape(reason)}</td></tr>"
      end
      out << "</tbody></table></div>"
    end

    def table_reachability_status(table)
      case table[:reachability_analyzed]
      when true then "analyzed"
      when false then "not analyzed"
      else "unknown (status not recorded)"
      end
    end

    def rule_reachability_status(rule)
      reachability = @coordinator.decision_table_reachability(rule)
      return "UNKNOWN" if reachability.to_s.empty? || reachability.to_s == "unknown"
      return "STATICALLY IMPOSSIBLE (excluded from denominator)" if reachability == "STATICALLY IMPOSSIBLE"

      reachability.to_s
    end

    def reachability_reason(rule)
      reason = fetch(rule, :reachability_reason)
      return "not recorded" if reason.to_s.empty?

      Branchproof::Constraints.message(reason)
    end

    def alternative_details(decision)
      rows = @alternatives.fetch(decision.id, [])
      return "" if rows.empty?

      out = +"<h3>Alternatives</h3><ul>"
      rows.each do |row|
        out << "<li><code>#{escape(row[:expression])}</code>: #{escape(row[:status])}"
        out << " — missing" if row[:missing]
        out << "</li>"
      end
      out << "</ul>"
    end

    def contributing_tests(decision)
      ids = decision.test_ids
      out = "<details><summary>Contributing tests; Tests reaching this decision (#{ids.length})</summary>"
      if ids.empty?
        out << "<p>No reaching tests recorded.</p>"
      else
        out << "<ul class=\"evidence\">"
        ids.each do |id|
          test = @tests[id] || {}
          label = fetch(test, :name) || id
          location = [fetch(test, :relative_path), fetch(test, :line)].compact.join(":")
          out << "<li>#{escape(label)}#{" (#{escape(location)})" unless location.empty?}</li>"
        end
        out << "</ul><p>Reaching a decision is not proof of MC/DC.</p>"
      end
      out << "</details>"
    end

    def diagnostics_html
      diagnostics = Array(fetch(@document, :diagnostics))
      return "" if diagnostics.empty?

      out = +"<section class=\"overview\" aria-labelledby=\"diagnostics-title\"><h2 id=\"diagnostics-title\">Diagnostics</h2><ul>"
      diagnostics.each { |item| out << "<li>#{escape(@coordinator.diagnostic_message(item))}</li>" }
      out << "</ul></section>"
    end

    def visible_decisions
      return [] unless @ranking.available?

      entries = @ranking.decisions
      entries = entries.select(&:gap?) if @missing_only
      @shown_decisions, @hidden_decisions = @selection.limit(entries)
      @shown_decisions
    end

    def hidden_decision_count
      visible_decisions
      return @hidden_decisions || 0 if @ranking.available?

      inventory = fetch(@document, :source_inventory) || fetch(@document, :inventory) || {}
      decisions = @selection.filter_decisions(Array(fetch(inventory, :decisions)), inventory: inventory)
      @selection.limit(decisions).last
    end

    def test_labels(ids)
      Array(ids).map do |id|
        test = @tests[id.to_s]
        next id.to_s unless test

        label = test[:name].to_s
        location = [test[:relative_path], test[:line]].compact.join(":")
        location.empty? ? label : "#{label} (#{location})"
      end
    end

    def inventory_decisions
      inventory = fetch(@document, :source_inventory) || fetch(@document, :inventory) || {}
      @selection.filter_decisions(Array(fetch(inventory, :decisions)), inventory: inventory)
    end

    def shown_inventory_decisions
      shown, @inventory_hidden = @selection.limit(inventory_decisions)
      shown
    end

    def escape(value)
      ERB::Util.html_escape(value.to_s)
    end

    def fetch(hash, key)
      return nil unless hash.respond_to?(:key?)

      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
  end
  # rubocop:enable Layout/LineLength
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
end
