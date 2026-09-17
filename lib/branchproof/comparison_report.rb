# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

require "json"

module Branchproof
  # Renders the offline document returned by Comparison.
  class ComparisonReport
    RULE_LABELS = Branchproof::DecisionTable::VALUE_LABELS.freeze

    def initialize(document:)
      raise ArgumentError, "comparison document must be a Hash" unless document.is_a?(Hash)

      @document = document
    end

    def write(io:, format:)
      format = format.to_sym
      raise ArgumentError, "format must be :terminal or :json" unless %i[terminal json].include?(format)

      io.write(format == :json ? JSON.generate(@document) : terminal_document)
      nil
    end

    def exit_code(fail_on_regression: false)
      return 2 if status != "complete"
      return 1 if fail_on_regression && (regression? || decision_table_regression?)

      0
    end

    private

    def terminal_document
      lines = ["Branchproof comparison", "Status: #{status}"]
      reasons.each { |reason| lines << "Reason: #{reason}" }
      Array(value(:context)).each { |item| lines << "Context: #{item}" }
      lines << "Conditions: #{matching.fetch("matched_conditions",
                                             0)} matched (denominator #{matching.fetch("denominator", 0)})"
      lines << "Before: #{summary_status(before)}; After: #{summary_status(after)}"
      lines << "Full-run totals: before #{totals(before)}; after #{totals(after)}"
      before_total = "#{matching["before_proven"] || 0}/#{matching["denominator"] || 0}"
      after_total = "#{matching["after_proven"] || 0}/#{matching["denominator"] || 0}"
      lines << "Exact-match totals: before #{before_total} proven; after #{after_total} proven"
      lines << "No comparable conditions." if matching.fetch("matched_conditions", 0).zero?
      changed_sources.each { |source| lines << "Source changed: #{source["relative_path"]}" }
      newly.each { |path| lines << "Newly in report: #{path}" }
      removed.each { |path| lines << "No longer in report: #{path}" }
      rendered_changes = changes.reject { |change| change["change"] == "unchanged" }
      if rendered_changes.empty?
        lines << "No comparable condition changes."
      else
        rendered_changes.each do |change|
          location = if change["relative_path"].to_s.empty?
                       "location unavailable"
                     else
                       "#{change["relative_path"]}:#{change["line"] || "condition line unavailable"}"
                     end
          lines << "#{change["change"].capitalize}: #{location} (condition #{change["index"]}) #{change["expression"]}"
          next unless change["change"] == "lost proof"

          owners = Array(change["previous_witness"]).flat_map { |witness| Array(witness["tests"]) }.uniq
          lines << "  Previous owners: #{owners.empty? ? "unavailable" : owners.join(", ")}"
          Array(change["previous_witness"]).each do |witness|
            outcome = witness["outcome"] ? "T" : "F"
            owners = Array(witness["tests"]).join(", ")
            lines << "  Previous witness: [#{signs(witness["values"])}] => #{outcome} — #{owners}"
          end
          context = Array(change["owner_context"]).map do |item|
            "#{item["label"]}: #{item["test_status"]}; [#{signs(item["values"])}] => " \
              "#{item["outcome"] ? "T" : "F"} #{item["observation_status"]}"
          end
          lines << "  #{context.empty? ? "not observed in current run" : context.join(", ")}"
        end
      end
      render_decision_tables(lines)
      lines.join("\n") << "\n"
    end

    # Coverage movement and analysis movement stay separate: a rule that became
    # statically impossible is an analysis change, never a coverage gain.
    def render_decision_tables(lines)
      matching = decision_table_matching
      lines << "Decision-table rules: #{matching.fetch("matched_rules", 0)} matched across " \
               "#{matching.fetch("compared_decisions", 0)} decisions"
      lines << "Decision-table rules covered: before #{matching.fetch("before_covered_rules",
                                                                      0)}; after #{matching.fetch(
                                                                        "after_covered_rules", 0
                                                                      )}"
      decision_table_context_changes.each do |change|
        location = change["relative_path"].to_s.empty? ? "location unavailable" : change["relative_path"].to_s
        lines << "Decision-table context: #{location} #{change["reason"]}"
      end
      rendered = decision_table_changes.reject { |change| change["change"] == "unchanged" }
      return lines << "No comparable decision-table rule changes." if rendered.empty?

      rendered.each { |change| render_decision_table_change(lines, change) }
    end

    def render_decision_table_change(lines, change)
      location = if change["relative_path"].to_s.empty?
                   "location unavailable"
                 else
                   "#{change["relative_path"]}:#{change["line"] || "decision line unavailable"}"
                 end
      signature = Array(change["conditions"]).map { |item| RULE_LABELS.fetch(item.to_s, item.to_s) }.join
      lines << "#{change["change"].capitalize}: #{location} rule #{change["label"]} " \
               "[#{signature}] => #{change["outcome"] ? "T" : "F"} #{change["expression"]}"
      lines << "  Previous: #{state_label(change["previous"])}"
      lines << "  Current: #{state_label(change["current"])}"
      reason = change.dig("current", "reachability_reason")
      lines << "  Reason: #{reason}" unless reason.to_s.empty?
    end

    def state_label(state)
      state ||= {}
      "#{state["coverage"] == "covered" ? "covered" : "uncovered"}, " \
        "reachability #{state["reachability"]}"
    end

    def status = value(:status).to_s

    def signs(values)
      Array(values).map do |item|
        if item.nil?
          "-"
        else
          (item ? "T" : "F")
        end
      end.join
    end

    def totals(summary)
      metrics = value_from(summary, :metrics) || {}
      "#{value_from(metrics,
                    :proven) || "unknown"}/#{value_from(metrics, :eligible_conditions) || "unknown"} conditions proven"
    end

    def regression? = value(:regression) == true || value(:regressions).to_i.positive?
    def decision_table_regression? = value(:decision_table_regressions).to_i.positive?
    def decision_table_changes = Array(value(:decision_table_changes))
    def decision_table_context_changes = Array(value(:decision_table_context_changes))
    def decision_table_matching = value(:decision_table_matching) || {}
    def reasons = Array(value(:reasons))
    def matching = value(:matching) || {}
    def before = value(:before) || {}
    def after = value(:after) || {}
    def changes = Array(value(:changes))
    def changed_sources = Array(value(:changed_sources))
    def newly = Array(value(:newly_in_report))
    def removed = Array(value(:no_longer_in_report))

    def summary_status(summary)
      value_from(summary, :status).to_s.upcase.then { |item| item.empty? ? "unknown" : item }
    end

    def value(key) = value_from(@document, key)

    def value_from(hash, key)
      return nil unless hash.respond_to?(:key?)

      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
