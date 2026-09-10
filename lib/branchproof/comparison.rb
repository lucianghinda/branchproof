# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
require "json"

module Branchproof
  # Compares two complete report documents without loading or executing the project.
  class Comparison
    SCHEMA_VERSION = "1.0"
    SUPPORTED_REPORT_SCHEMAS = %w[1.0 1.1 1.2].freeze
    CRITERION_VERSION = "masking_occurrence_v1"

    def initialize(before:, after:)
      @before = before
      @after = after
      @contexts = {}.compare_by_identity
    end

    def call
      errors = validate_documents
      return invalid_result(errors) unless errors.empty?

      before_sources = sources(@before)
      after_sources = sources(@after)
      changed_paths = before_sources.keys & after_sources.keys
      changed_paths.reject! { |path| digest(before_sources[path]) == digest(after_sources[path]) }
      before_conditions = condition_map(@before)
      after_conditions = condition_map(@after)
      matched_ids = before_conditions.keys & after_conditions.keys
      matched_ids.select! do |id|
        compatible_condition?(before_conditions[id], after_conditions[id], changed_paths, before_sources,
                              after_sources)
      end
      changes = matched_ids.filter_map { |id| condition_change(id, before_conditions[id], after_conditions[id]) }
      reasons = comparability_reasons(changed_paths)
      reasons.concat(metadata_requirements)
      reasons << "legacy report is missing comparison context" if [@before, @after].any? do |document|
        value(document, :schema_version).to_s == "1.0" && value(document, :run_metadata).nil?
      end
      complete = complete_run?(@before) && complete_run?(@after)
      reasons << "run baselines are not successful finalized complete reports" unless complete
      reasons << "no comparable conditions" if matched_ids.empty?
      if changes.any? { |change| [change["status_before"], change["status_after"]].include?("UNKNOWN") }
        reasons << "condition proof status unavailable"
      end
      if before_sources.keys.sort != after_sources.keys.sort
        reasons << "source population differs; whole-source comparison is partial"
      end
      if matched_ids.length != before_conditions.length || matched_ids.length != after_conditions.length
        reasons << "unmatched conditions; exact-match scope is partial"
      end
      status = reasons.empty? ? "complete" : "comparison incomplete"
      lost = changes.count { |change| change["change"] == "lost proof" }

      {
        "schema_version" => SCHEMA_VERSION,
        "criterion_version" => CRITERION_VERSION,
        "status" => status,
        "comparison_status" => status,
        "reasons" => reasons,
        "before" => summary(@before),
        "after" => summary(@after),
        "context" => context_changes,
        "matching" => { "before_conditions" => before_conditions.length,
                        "after_conditions" => after_conditions.length,
                        "matched_conditions" => matched_ids.length,
                        "denominator" => matched_ids.length,
                        "before_proven" => changes.count { |change| change["status_before"] == "PROVEN" },
                        "after_proven" => changes.count { |change| change["status_after"] == "PROVEN" } },
        "changed_sources" => changed_paths.sort.map do |path|
          { "relative_path" => path, "reason" => "source changed / condition comparison unavailable" }
        end,
        "newly_in_report" => (after_sources.keys - before_sources.keys).sort,
        "no_longer_in_report" => (before_sources.keys - after_sources.keys).sort,
        "changes" => changes.sort_by do |change|
          [change["relative_path"].to_s, change["line"].to_i, change["condition_id"]]
        end,
        "regressions" => lost,
        "regression" => lost.positive? && status == "complete"
      }
    end

    private

    def validate_documents
      errors = []
      { "before" => @before, "after" => @after }.each do |label, document|
        errors << "#{label} report must be an object" unless document.is_a?(Hash)
        next unless document.is_a?(Hash)

        schema = value(document, :schema_version).to_s
        criterion = value(document, :criterion_version).to_s
        errors << "#{label} report has unsupported schema" unless SUPPORTED_REPORT_SCHEMAS.include?(schema)
        errors << "#{label} report has incompatible criterion" unless criterion == CRITERION_VERSION
        errors << "#{label} source_inventory must be an object" unless value(document, :source_inventory).is_a?(Hash)
      end
      errors.uniq
    end

    def invalid_result(errors)
      { "schema_version" => SCHEMA_VERSION, "status" => "comparison incomplete",
        "comparison_status" => "comparison incomplete", "reasons" => errors,
        "before" => summary(@before), "after" => summary(@after),
        "matching" => { "before_conditions" => 0, "after_conditions" => 0,
                        "matched_conditions" => 0, "denominator" => 0 },
        "changed_sources" => [], "newly_in_report" => [], "no_longer_in_report" => [],
        "changes" => [], "regressions" => 0, "regression" => false }
    end

    def sources(document)
      units = value(value(document, :source_inventory), :source_units)
      Array(units).each_with_object({}) do |source, result|
        path = value(source, :relative_path).to_s
        result[path] = source unless path.empty?
      end
    end

    def condition_map(document)
      data = context(document)
      data[:decisions].values.each_with_object({}) do |decision, result|
        next if value(decision, :support_status).to_s == "UNSUPPORTED"

        Array(value(decision, :conditions)).each do |condition|
          id = value(condition, :id).to_s
          unless id.empty?
            result[id] = { condition: condition, row: data[:conditions][id], decision: decision,
                           result: data[:results][id] }
          end
        end
      end
    end

    def compatible_condition?(before, after, changed_paths, before_sources, after_sources)
      before_path = source_path(@before, before[:decision])
      after_path = source_path(@after, after[:decision])
      return false if before_path.nil? || changed_paths.include?(before_path) || before_path != after_path

      before_digest = digest(before_sources[before_path])
      after_digest = digest(after_sources[after_path])
      return false unless before_digest && before_digest == after_digest

      %i[index expression byte_start byte_length].all? do |key|
        value(before[:condition], key) == value(after[:condition], key)
      end && %i[id source_id expression context byte_start byte_length tree].all? do |key|
        Records.normalize(value(before[:decision], key)) == Records.normalize(value(after[:decision], key))
      end
    end

    def condition_change(id, before, after)
      old_status = status(before[:result], @before)
      new_status = status(after[:result], @after)
      if new_status == "NOT_PROVEN" && !complete_run?(@after) &&
         context(@after)[:vectors].values.none? { |vector| value(vector, :decision_id) == value(after[:decision], :id) }
        new_status = "UNKNOWN"
      end
      kind = if old_status == "PROVEN" && new_status == "NOT_PROVEN"
               "lost proof"
             elsif old_status == "NOT_PROVEN" && new_status == "PROVEN"
               "gained proof"
             elsif old_status == new_status
               "unchanged"
             else
               "unknown"
             end
      return if kind.nil?

      decision = after[:decision]
      source_path = source_path(@after, decision)
      row = { "condition_id" => id, "change" => kind, "status_before" => old_status,
              "status_after" => new_status, "expression" => value(after[:condition], :expression),
              "relative_path" => source_path, "line" => value(after[:condition], :line),
              "index" => value(after[:condition], :index),
              "previous_witness" => witness(@before, before[:result], before[:decision]),
              "current_witness" => witness(@after, after[:result], after[:decision]) }
      row["previous_witness_owners"] = row["previous_witness"].to_a.flat_map { |item| item["tests"] }.uniq
      row["current_witness_owners"] = row["current_witness"].to_a.flat_map { |item| item["tests"] }.uniq
      row["owner_context"] = owner_context(before[:result], before[:decision])
      row
    end

    def context(document)
      @contexts[document] ||= begin
        index = CoverageIndex.new(document: document)
        tests = Array(value(value(document, :observations), :tests)).to_h { |test| [value(test, :id).to_s, test] }
        rows = index.tests.to_h { |test| [test[:id].to_s, test] }
        keys = tests.to_h do |id, test|
          parts = %i[adapter class_name method_name].map { |key| value(test, key) }
          parts << rows.dig(id, :relative_path)
          [id, parts.all? { |part| part.is_a?(String) && !part.empty? } ? parts : nil]
        end
        results = Array(value(value(document, :analysis), :decisions)).flat_map do |decision|
          Array(value(decision, :condition_results))
        end
        vectors = Array(value(value(document, :observations), :vectors))
        { conditions: index.conditions.to_h { |row| [row[:id].to_s, row] }, tests: tests, test_rows: rows,
          test_keys: keys, key_owners: keys.keys.group_by { |id| keys[id] },
          vectors: vectors.to_h { |vector| [value(vector, :id).to_s, vector] },
          vectors_by_decision: vectors.group_by { |vector| value(vector, :decision_id).to_s },
          decisions: Array(value(value(document, :source_inventory), :decisions)).to_h do |decision|
            [value(decision, :id).to_s, decision]
          end,
          results: results.to_h { |result| [value(result, :condition_id).to_s, result] } }
      end
    end

    def owner_context(result, decision)
      before = context(@before)
      after = context(@after)
      Array(value(result, :canonical_pair)).flat_map do |vector_id|
        vector = before[:vectors][vector_id.to_s]
        next [] unless vector

        Array(value(vector, :test_ids)).sort.map do |id|
          key = before[:test_keys][id.to_s]
          unique = key && before[:key_owners][key]&.length == 1 && after[:key_owners][key]&.length == 1
          current_id = unique ? after[:key_owners][key].first : nil
          decision_vectors = after[:vectors_by_decision][value(decision, :id).to_s]
          observed = current_id && Array(decision_vectors).any? do |current|
            value(current, :values) == value(vector, :values) && value(current, :outcome) == value(vector, :outcome) &&
              Array(value(current, :test_ids)).include?(current_id)
          end
          test_status = current_id ? "present in current run" : "not observed in current run (no unique test match)"
          { "label" => test_display(@before, id), "current_label" => current_id && test_display(@after, current_id),
            "test_status" => test_status,
            "observation_status" => observed ? "observed in current run" : "not observed in current run",
            "values" => value(vector, :values), "outcome" => value(vector, :outcome) }
        end
      end
    end

    def witness(document, result, _decision)
      pair = value(result, :canonical_pair)
      return nil unless pair.is_a?(Array)

      pair.map do |id|
        vector = context(document)[:vectors][id.to_s]
        { "vector_id" => id, "values" => value(vector, :values), "outcome" => value(vector, :outcome),
          "tests" => Array(value(vector, :test_ids)).map { |test_id| test_display(document, test_id) }.uniq.sort }
      end
    end

    def test_display(document, id)
      row = context(document)[:test_rows][id.to_s]
      return "unknown test (location unavailable)" unless row

      path = row[:relative_path]
      location = path && row[:line] ? "#{path}:#{row[:line]}" : "location unavailable"
      "#{row[:name]} (#{location})"
    end

    def context_changes
      changes = []
      if metadata(@before, :seed) != metadata(@after, :seed)
        changes << "seed differs: #{metadata(@before, :seed).inspect} -> #{metadata(@after, :seed).inspect}"
      end
      if metadata(@before, :test_files) != metadata(@after, :test_files)
        changes << "expanded test files differ under the recorded selection patterns"
      end
      if context(@before)[:test_keys].values.sort_by(&:to_s) != context(@after)[:test_keys].values.sort_by(&:to_s)
        changes << "test population differs"
      end
      changes << "Deltas describe observed runs; nondeterminism and external environment changes are not ruled out."
      changes
    end

    def comparability_reasons(changed_paths)
      reasons = []
      reasons << "source files changed: #{changed_paths.sort.join(", ")}" unless changed_paths.empty?
      %i[project_kind runner_args source_patterns test_patterns limits runtime].each do |key|
        left = metadata(@before, key)
        right = metadata(@after, key)
        if key == :runner_args
          left = comparable_runner_args(left)
          right = comparable_runner_args(right)
        end
        reasons << "#{key} differs" if !left.nil? && !right.nil? && left != right
      end
      reasons << "source selection differs" if source_selection(@before) != source_selection(@after)
      reasons
    end

    def source_selection(document)
      value(value(document, :run_metadata), :source_patterns)
    end

    def metadata_requirements
      [@before, @after].each_with_index.filter_map do |document, index|
        metadata = value(document, :run_metadata)
        required = %i[project_kind source_patterns test_patterns test_files runner_args limits]
        missing = required.reject { |key| metadata.is_a?(Hash) && !value(metadata, key).nil? }
        missing << :runtime unless value(document, :runtime).is_a?(String) && !value(document, :runtime).empty?
        if missing.empty?
          nil
        else
          "#{index.zero? ? "before" : "after"} report missing run metadata: #{missing.join(", ")}"
        end
      end
    end

    def metadata(document, key)
      value(value(document, :run_metadata), key) || value(document, key)
    end

    def complete_run?(document)
      baseline = value(document, :baseline) || {}
      completeness = value(document, :completeness) || {}
      analysis = value(document, :analysis)
      return false unless value(baseline, :status).to_s.upcase == "PASSED" && value(baseline, :finalized) == true
      return false unless analysis.is_a?(Hash)

      [completeness, value(analysis, :completeness),
       value(value(document, :observations), :completeness)].all? do |section|
        %i[observation attribution analysis].all? { |key| value(section, key) == true }
      end
    end

    def summary(document)
      { "run_id" => Array(value(value(document, :observations), :run_ids)).first,
        "status" => value(value(document, :baseline), :status), "metrics" => value(document, :metrics),
        "completeness" => value(document, :completeness), "run_metadata" => value(document, :run_metadata) }
    end

    def source_path(document, decision)
      units = value(value(document, :source_inventory), :source_units)
      source = Array(units).find { |item| value(item, :source_id).to_s == value(decision, :source_id).to_s }
      value(source, :relative_path) || value(decision, :relative_path)
    end

    def digest(source) = value(source, :digest) || value(source, :content_digest)

    def comparable_runner_args(args)
      skip_next = false
      Array(args).each_with_object([]) do |arg, result|
        text = arg.to_s
        if skip_next
          skip_next = false
          next
        end
        if ["--seed", "-s"].include?(text)
          skip_next = true
          next
        end
        next if text.start_with?("--seed=")

        result << arg
      end
    end

    def status(result, _document = nil)
      text = value(result, :status).to_s.upcase
      return text unless text.empty?

      "UNKNOWN"
    end

    def value(hash, key)
      return nil unless hash.respond_to?(:key?)

      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
  end
end
# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
