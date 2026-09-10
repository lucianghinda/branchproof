# frozen_string_literal: true

require "json"

module Branchproof
  # Renders versioned terminal and JSON analysis reports.
  class Report
    SCHEMA_VERSION = "1.0"
    CRITERION_VERSION = "masking_occurrence_v1"

    def initialize(inventory:, evidence:, analysis:, minima:, baseline:, diagnostics:, level: 3)
      raise ArgumentError, "level must be 1, 2, or 3" unless [1, 2, 3].include?(level.to_i)

      @inventory = inventory || {}
      @evidence = evidence || {}
      @analysis = analysis
      @minima = Array(minima)
      @baseline = baseline || {}
      @diagnostics = Array(diagnostics)
      @level = level.to_i
    end

    def write(io:, format:)
      format = format.to_sym
      raise ArgumentError, "format must be :terminal or :json" unless %i[terminal json].include?(format)

      io.write(format == :json ? JSON.generate(json_document) : terminal_document)
      nil
    end

    def exit_code
      return 2 unless usage_valid?

      status = value(@baseline, :status).to_s.upcase
      return 2 if %w[ERROR INCOMPLETE].include?(status)
      return 1 if status == "FAILED"
      return 2 unless status == "PASSED" && value(@baseline, :finalized) == true
      return 2 unless metrics[:eligible_conditions].positive?
      return 2 unless valid_for_requested_level?

      0
    end

    private

    def json_document
      normalize(schema_version: SCHEMA_VERSION,
                tool_version: (defined?(Branchproof::VERSION) ? Branchproof::VERSION : "unknown"),
                criterion_version: CRITERION_VERSION, runtime: RUBY_DESCRIPTION,
                run_ids: Array(value(@evidence, :run_ids)),
                source_inventory: @inventory, baseline: @baseline, observations: @evidence,
                analysis: @level == 1 ? nil : @analysis, minima: @minima, metrics: metrics,
                diagnostics: @diagnostics, completeness: completeness)
    end

    def terminal_document
      @terminal_ids = terminal_ids
      lines = ["Branchproof #{defined?(Branchproof::VERSION) ? Branchproof::VERSION : "unknown"}",
               "Tests: #{baseline_status} (#{baseline_test_counts})",
               terminal_coverage_line,
               "Analysis: #{terminal_analysis_status}",
               "Decisions: #{metrics[:supported]} supported, #{metrics[:unsupported]} excluded, " \
               "#{metrics[:unexecuted]} unexecuted (#{metrics[:discovered]} discovered)",
               "Observations: #{metrics[:completed]} completed, #{metrics[:aborted]} aborted, " \
               "#{metrics[:unattributed]} unattributed",
               "Values: T=true, F=false, -=short-circuited"]
      lines << "Scope: supported decisions and conditions"
      lines << ""
      inventory_decisions.each { |decision| render_decision(lines, decision) }
      render_minima(lines)
      unless @diagnostics.empty?
        lines << "Diagnostics:"
        @diagnostics.each { |diagnostic| lines << "  - #{value(diagnostic, :message) || value(diagnostic, :code)}" }
      end
      lines.join("\n") << "\n"
    end

    def render_decision(lines, decision)
      source = source_for(decision)
      filename = value(source, :relative_path) || value(source, :absolute_path) || value(decision, :source_id)
      decision_label = "Decision #{short_id(value(decision, :id))} #{filename}:#{value(decision, :line)}"
      lines << decision_label
      lines << "  Decision: #{value(decision, :expression)}"
      lines << "  Status: #{value(decision, :support_status) || "SUPPORTED"}"
      Array(value(decision, :conditions)).each do |condition|
        result = condition_result(decision, condition)
        detail = condition_detail(result)
        status = if @analysis.nil? || @level == 1
                   "NOT CALCULATED"
                 else
                   value(result, :status) || "NOT_PROVEN"
                 end
        lines << "  Condition #{value(condition, :index)}: #{value(condition, :expression)}"
        lines << "    #{status}#{detail}"
      end
      vectors_for(decision).each do |vector|
        values = Array(value(vector, :values)).map do |item|
          if item.nil?
            "-"
          else
            item ? "T" : "F"
          end
        end.join
        owners = Array(value(vector, :test_ids)).map { |test_id| test_label(test_id) }
        owners << "unattributed" if value(vector, :unattributed_count).to_i.positive?
        vector_label = "  Vector #{short_id(value(vector, :id))} [#{values}] => " \
                       "#{value(vector, :outcome) ? "T" : "F"}"
        lines << "#{vector_label} owners=#{owners.join(", ")}"
      end
      lines << ""
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
      return "not calculated" if @analysis.nil? || @level == 1

      coverage_label
    end

    def terminal_coverage_line
      return "MC/DC: not calculated" if @analysis.nil? || @level == 1

      "MC/DC: #{terminal_coverage_label} (#{metrics[:proven]}/#{metrics[:eligible_conditions]} conditions proven)"
    end

    def terminal_analysis_status
      return "NOT CALCULATED" if @analysis.nil? || @level == 1

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
      location = value(test, :source)
      source_line = nil
      if location.respond_to?(:key?)
        source_line = value(location, :line)
        location = value(location, :path) || value(location, :relative_path)
      end
      location ||= value(test, :source_path)
      line = value(test, :line) || value(test, :source_line) || source_line
      [location, line]
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
      Array(value(analysis_for(decision), :condition_results)).find do |item|
        value(item, :condition_id).to_s == value(condition, :id).to_s
      end
    end

    def condition_detail(result)
      return "" unless result && @level == 3

      pair = value(result, :canonical_pair)
      return " (witness #{Array(pair).map { |id| short_id(id) }.join(" + ")})" if pair

      constraint = value(result, :constraint_result)
      if constraint
        constraints = Array(value(constraint, :constraints)).map { |item| item.is_a?(Hash) ? item.inspect : item.to_s }
        detail = constraints.empty? ? value(constraint, :status) : constraints.join(", ")
        statement = value(constraint, :feasibility_statement)
        detail = [detail, statement].compact.reject(&:empty?).join("; ")
        return " (missing counterpart: #{detail})" unless detail.empty?
      end

      ""
    end

    def metrics
      decisions = inventory_decisions
      supported = decisions.reject { |decision| unsupported?(decision) }
      unsupported = decisions.select { |decision| unsupported?(decision) }
      eligible = supported.sum { |decision| Array(value(decision, :conditions)).length }
      observed = vectors.map { |vector| value(vector, :decision_id).to_s }.uniq
      proven = @analysis ? value(@analysis, :proven_count).to_i : 0
      { discovered: decisions.length, supported: supported.length, unsupported: unsupported.length,
        unsupported_conditions: unsupported.sum do |decision|
          discovered_conditions(decision)
        end, eligible_conditions: eligible,
        opaque: decisions.sum { |decision| Array(value(decision, :opaque_ranges)).length },
        unexecuted: supported.count { |decision| !observed.include?(value(decision, :id).to_s) },
        completed: vectors.sum do |vector|
          value(vector, :count).to_i
        end, aborted: numeric_hash_value(@evidence, :abort_counts),
        unattributed: vectors.sum { |vector| value(vector, :unattributed_count).to_i }, limited: incomplete? ? 1 : 0,
        proven: proven, percentage: percentage(eligible, proven) }
    end

    def completeness
      evidence = value(@evidence, :completeness) || {}
      analysis = value(@analysis, :completeness) || {}
      { observation: completeness_value?(evidence, analysis, :observation),
        attribution: completeness_value?(evidence, analysis, :attribution),
        analysis: @analysis ? value(analysis, :analysis) == true : value(evidence, :analysis) == true }
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
      return completeness[:observation] && completeness[:attribution] if @level == 1

      completeness.values.all? { |item| item == true }
    end

    def coverage_label
      percentage = metrics[:percentage]
      return "N/A" if percentage.nil?

      incomplete? ? "#{percentage}% (lower-bound; incomplete evidence)" : "#{percentage}%"
    end

    def analysis_status
      return "NOT_REQUESTED" if @analysis.nil? || @level == 1

      valid_for_requested_level? ? "COMPLETE" : "PARTIAL"
    end

    def incomplete?
      !completeness[:observation] || !completeness[:attribution] || (@level > 1 && !completeness[:analysis])
    end

    def vectors_for(decision)
      vectors.select do |vector|
        value(vector, :decision_id).to_s == value(decision, :id).to_s
      end
    end

    def analysis_for(decision)
      Array(value(@analysis, :decisions)).find do |item|
        value(item, :decision_id).to_s == value(decision, :id).to_s
      end
    end

    def source_for(decision)
      Array(value(@inventory, :source_units)).find do |source|
        value(source, :source_id).to_s == value(decision, :source_id).to_s
      end || decision
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
  end
end
