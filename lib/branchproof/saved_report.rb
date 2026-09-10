# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

require "json"

module Branchproof
  # Reads and validates a persisted JSON report without loading the project.
  class SavedReport
    SUPPORTED_SCHEMAS = %w[1.0 1.1].freeze
    CRITERION_VERSION = "masking_occurrence_v1"
    REQUIRED_FIELDS = %w[schema_version tool_version criterion_version runtime run_ids source_inventory baseline
                         observations analysis minima metrics diagnostics completeness].freeze
    COMPLETENESS_FIELDS = %w[observation attribution analysis].freeze

    class << self
      def read(path)
        raise ArgumentError, "report path must be a string" unless path.is_a?(String)

        json = File.binread(path)
        document = JSON.parse(json)
        new(document).validate!
      rescue IOError, SystemCallError => e
        raise ArgumentError, "cannot read report: #{e.message}"
      rescue JSON::ParserError
        raise ArgumentError, "invalid report JSON"
      end
    end

    def initialize(document)
      @document = document
    end

    def validate!
      fail_with("document must be an object") unless hash_with_string_keys?(@document)
      schema = @document["schema_version"]
      fail_with("unsupported schema version") unless SUPPORTED_SCHEMAS.include?(schema)
      missing = REQUIRED_FIELDS.reject { |field| @document.key?(field) }
      fail_with("missing field: #{missing.first}") unless missing.empty?
      fail_with("criterion version mismatch") unless @document["criterion_version"] == CRITERION_VERSION
      fail_with("run_ids must be an array of strings") unless strings?(@document["run_ids"])

      validate_inventory(@document["source_inventory"])
      validate_observations(@document["observations"])
      validate_baseline(@document["baseline"])
      validate_analysis(@document["analysis"])
      validate_completeness(@document["completeness"])
      validate_completeness(@document.dig("observations", "completeness"))
      validate_completeness(@document.dig("analysis", "completeness")) if @document["analysis"]
      validate_optional_sections
      validate_analysis_coverage
      @document
    end

    private

    def validate_inventory(inventory)
      fail_with("source_inventory must be an object") unless hash_with_string_keys?(inventory)
      validate_string_field(inventory, "root", nullable: true)
      sources = inventory["source_units"]
      decisions = inventory["decisions"]
      fail_with("source_units must be an array") unless sources.is_a?(Array)
      fail_with("decisions must be an array") unless decisions.is_a?(Array)
      source_ids = unique_ids(sources, "source_id", "source")
      decision_ids = unique_ids(decisions, "id", "decision")
      decisions.each do |decision|
        fail_with("invalid decision") unless hash_with_string_keys?(decision)
        fail_with("unknown decision source") unless source_ids.include?(decision["source_id"])
        validate_string_field(decision, "expression")
        validate_integer_field(decision, "line")
        conditions = decision["conditions"]
        fail_with("conditions must be an array") unless conditions.is_a?(Array)
        unique_ids(conditions, "id", "condition")
        conditions.each do |condition|
          fail_with("invalid condition") unless hash_with_string_keys?(condition) && condition["index"].is_a?(Integer)
          validate_string_field(condition, "expression")
          %w[line column byte_start byte_length].each do |field|
            validate_integer_field(condition, field, nullable: true)
          end
        end
        fail_with("condition indexes must be consecutive") unless conditions.map do |condition|
          condition["index"]
        end.sort == (0...conditions.length).to_a
      end
      @source_ids = source_ids
      @decision_ids = decision_ids
      @condition_ids = decisions.flat_map do |decision|
        Array(decision["conditions"]).map do |condition|
          condition["id"]
        end
      end
      fail_with("duplicate condition id") unless @condition_ids.uniq.length == @condition_ids.length
      @conditions_by_decision = decisions.to_h do |decision|
        [decision["id"], Array(decision["conditions"]).map { |condition| condition["id"] }]
      end
      sources.each do |source|
        validate_string_field(source, "relative_path", nullable: true)
        validate_string_field(source, "absolute_path", nullable: true)
        digest = source["digest"] || source["content_digest"]
        fail_with("source digest must be a nonempty string") unless digest.is_a?(String) && !digest.empty?
      end
      paths = sources.map { |source| source["relative_path"] }.compact
      fail_with("duplicate source relative path") unless paths.uniq.length == paths.length
      @condition_counts = decisions.to_h { |decision| [decision["id"], decision["conditions"].length] }
      @supported_ids = decisions.filter_map do |decision|
        decision["id"] unless decision["support_status"] == "UNSUPPORTED"
      end
    end

    def validate_observations(observations)
      fail_with("observations must be an object") unless hash_with_string_keys?(observations)
      tests = observations["tests"]
      vectors = observations["vectors"]
      fail_with("tests must be an array") unless tests.is_a?(Array)
      fail_with("vectors must be an array") unless vectors.is_a?(Array)
      @test_ids = unique_ids(tests, "id", "test")
      tests.each { |test| validate_test(test) }
      vector_ids = unique_ids(vectors, "id", "vector")
      vectors.each do |vector|
        fail_with("invalid vector") unless hash_with_string_keys?(vector)
        fail_with("unknown vector decision") unless @decision_ids.include?(vector["decision_id"])
        values = vector["values"]
        valid_values = values.is_a?(Array) && values.all? do |value|
          value.nil? || value == true || value == false
        end
        fail_with("vector values must be an array of booleans or null") unless valid_values
        expected_length = @condition_counts.fetch(vector["decision_id"])
        fail_with("vector values do not match decision conditions") unless values.length == expected_length
        fail_with("vector outcome must be boolean") unless [true, false].include?(vector["outcome"])
        fail_with("unknown vector test") unless strings?(vector["test_ids"]) && vector["test_ids"].all? do |id|
          @test_ids.include?(id)
        end
        validate_phases(vector)
        validate_integer_field(vector, "count")
        validate_integer_field(vector, "unattributed_count")
      end
      @vector_ids = vector_ids
      @vector_decision_by_id = vectors.to_h { |vector| [vector["id"], vector["decision_id"]] }
      aborts = observations["abort_counts"]
      return if aborts.nil? || aborts.is_a?(Integer) || (aborts.is_a?(Hash) && aborts.values.all?(Integer))

      fail_with("invalid abort_counts")
    end

    def validate_baseline(baseline)
      fail_with("baseline must be an object") unless hash_with_string_keys?(baseline)
      fail_with("baseline status must be a string") unless baseline["status"].is_a?(String)
      fail_with("baseline finalized must be boolean") unless [true, false].include?(baseline["finalized"])
      return unless baseline.key?("tests")

      fail_with("baseline tests must be an array") unless baseline["tests"].is_a?(Array)
      unique_ids(baseline["tests"], "id", "baseline test")
      baseline["tests"].each { |test| validate_test(test) }
    end

    def validate_analysis(analysis)
      return if analysis.nil?

      fail_with("analysis must be an object") unless hash_with_string_keys?(analysis)
      %w[proven_count eligible_count].each { |field| validate_integer_field(analysis, field) }
      decisions = analysis["decisions"]
      fail_with("analysis decisions must be an array") unless decisions.is_a?(Array)
      seen = {}
      decisions.each do |decision|
        fail_with("invalid analysis decision") unless hash_with_string_keys?(decision)
        id = decision["decision_id"]
        fail_with("unknown analysis decision") unless @decision_ids.include?(id) && !seen.key?(id)
        seen[id] = true
        results = decision["condition_results"]
        fail_with("condition results must be an array") unless results.is_a?(Array)
        seen_conditions = {}
        results.each do |result|
          condition_id = result["condition_id"] if hash_with_string_keys?(result)
          fail_with("invalid condition result") unless @conditions_by_decision.fetch(id).include?(condition_id)
          fail_with("duplicate condition result") if seen_conditions.key?(condition_id)
          seen_conditions[condition_id] = true
          validate_constraint(result["constraint_result"], id) if result["constraint_result"]
          next unless result.key?("canonical_pair")

          next if result["canonical_pair"].nil?

          pair = result["canonical_pair"]
          valid_pair = pair.is_a?(Array) && pair.length == 2 && pair.uniq.length == 2 && pair.all? do |id|
            @vector_ids.include?(id) && @vector_decision_by_id[id] == decision["decision_id"]
          end
          fail_with("canonical pair must reference vectors") unless valid_pair
        end
      end
    end

    def validate_completeness(completeness)
      fail_with("completeness must be an object") unless hash_with_string_keys?(completeness)
      COMPLETENESS_FIELDS.each do |field|
        valid = completeness.key?(field) && [true, false].include?(completeness[field])
        fail_with("completeness #{field} must be boolean") unless valid
      end
    end

    def validate_optional_sections
      fail_with("minima must be an array") unless @document["minima"].is_a?(Array)
      fail_with("metrics must be an object") unless hash_with_string_keys?(@document["metrics"])
      fail_with("diagnostics must be an array") unless @document["diagnostics"].is_a?(Array)
      @document["diagnostics"].each do |diagnostic|
        fail_with("invalid diagnostic") unless hash_with_string_keys?(diagnostic)
      end
      @document["minima"].each { |minimum| validate_minimum(minimum) }
      if @document.key?("run_metadata") && !hash_with_string_keys?(@document["run_metadata"])
        fail_with("run_metadata must be an object")
      end
      validate_metadata(@document["run_metadata"]) if @document["run_metadata"]
      fail_with("document contains non-string object keys") unless all_hashes_have_string_keys?(@document)
    end

    def validate_phases(vector)
      phases = vector["phases_by_test"]
      return if phases.nil?

      valid = hash_with_string_keys?(phases) && phases.all? do |test_id, values|
        valid_phases = %w[setup body teardown suite unattributed]
        @test_ids.include?(test_id) && strings?(values) && values.all? { |phase| valid_phases.include?(phase) }
      end
      fail_with("invalid phases_by_test") unless valid
    end

    def validate_test(test)
      %w[name class_name method_name source_path].each { |field| validate_string_field(test, field, nullable: true) }
      validate_integer_field(test, "line", nullable: true)
      phase_counts = test["phase_counts"]
      if phase_counts
        valid = hash_with_string_keys?(phase_counts) && phase_counts.values.all?(Integer)
        fail_with("invalid test phase_counts") unless valid
      end
      source = test["source"]
      return if source.nil?

      fail_with("test source must be an object") unless hash_with_string_keys?(source)
      validate_string_field(source, "path", nullable: true)
      validate_string_field(source, "relative_path", nullable: true)
      validate_integer_field(source, "line", nullable: true)
    end

    # Keep each record's shape and reference checks together.
    def validate_minimum(minimum)
      fail_with("invalid minimum") unless hash_with_string_keys?(minimum)
      %w[scope_decision_ids selected_ids].each do |field|
        fail_with("minimum #{field} must be an array of strings") if minimum.key?(field) && !strings?(minimum[field])
      end
      validate_string_field(minimum, "objective", nullable: true)
      validate_string_field(minimum, "status", nullable: true)
      scope = minimum["scope_decision_ids"] || []
      fail_with("unknown minimum decision") unless (scope - @decision_ids).empty?
      ids = minimum["objective"] == "tests" ? @test_ids : @vector_ids
      fail_with("unknown minimum member") unless ((minimum["selected_ids"] || []) - ids).empty?
    end

    def validate_constraint(constraint, decision_id)
      fail_with("constraint_result must be an object") unless hash_with_string_keys?(constraint)
      %w[status feasibility_statement].each { |field| validate_string_field(constraint, field, nullable: true) }
      %w[constraints candidate_vectors].each do |field|
        fail_with("#{field} must be an array") if constraint.key?(field) && !constraint[field].is_a?(Array)
      end
      Array(constraint["candidate_vectors"]).each do |candidate|
        fail_with("invalid candidate vector") unless hash_with_string_keys?(candidate)
        values = candidate["values"]
        unless values.is_a?(Array) && values.length == @condition_counts[decision_id] && values.all? do |item|
          [true, false, nil].include?(item)
        end
          fail_with("invalid candidate values")
        end
        fail_with("invalid candidate outcome") unless [true, false].include?(candidate["outcome"])
      end
      existing = constraint["existing_vector_id"]
      fail_with("unknown constraint vector") if existing && @vector_decision_by_id[existing] != decision_id
    end

    def validate_analysis_coverage
      analysis = @document["analysis"]
      return unless analysis && analysis.dig("completeness", "analysis") == true

      results = analysis["decisions"].to_h { |decision| [decision["decision_id"], decision["condition_results"]] }
      @supported_ids.each do |id|
        actual = Array(results[id]).map { |result| result["condition_id"] }.sort
        fail_with("complete analysis is missing condition results") unless actual == @conditions_by_decision[id].sort
      end
    end

    def validate_string_field(record, field, nullable: false)
      return unless record.key?(field)
      return if nullable && record[field].nil?

      fail_with("#{field} must be a string") unless record[field].is_a?(String)
    end

    def validate_integer_field(record, field, nullable: false)
      return unless record.key?(field)
      return if nullable && record[field].nil?

      fail_with("#{field} must be an integer") unless record[field].is_a?(Integer)
    end

    def validate_metadata(metadata)
      string_fields = %w[captured_at project_kind project_root]
      string_fields.each do |field|
        fail_with("run_metadata #{field} must be a string") if metadata.key?(field) && !metadata[field].is_a?(String)
      end
      array_fields = %w[source_patterns test_patterns test_files runner_args]
      array_fields.each do |field|
        if metadata.key?(field) && !strings?(metadata[field])
          fail_with("run_metadata #{field} must be an array of strings")
        end
      end
      if metadata.key?("requested_level") && !metadata["requested_level"].is_a?(Integer)
        fail_with("run_metadata requested_level must be an integer")
      end
      if metadata.key?("limits") && !hash_with_string_keys?(metadata["limits"])
        fail_with("run_metadata limits must be an object")
      end
      locations = metadata["test_locations"]
      return unless locations

      valid = hash_with_string_keys?(locations) && locations.all? do |test_id, location|
        @test_ids.include?(test_id) && hash_with_string_keys?(location) &&
          (!location.key?("relative_path") || location["relative_path"].nil? ||
            location["relative_path"].is_a?(String)) &&
          (!location.key?("line") || location["line"].nil? || location["line"].is_a?(Integer))
      end
      fail_with("invalid run_metadata test_locations") unless valid
    end

    def unique_ids(items, field, label)
      ids = items.map do |item|
        unless hash_with_string_keys?(item) && item[field].is_a?(String) && !item[field].empty?
          fail_with("invalid #{label} record")
        end
        item[field]
      end
      fail_with("duplicate #{label} id") unless ids.uniq.length == ids.length
      ids
    end

    def strings?(value)
      value.is_a?(Array) && value.all?(String)
    end

    def hash_with_string_keys?(value)
      value.is_a?(Hash) && value.keys.all?(String)
    end

    def all_hashes_have_string_keys?(value)
      return true unless value.is_a?(Hash)
      return false unless hash_with_string_keys?(value)

      value.values.all? do |item|
        all_hashes_have_string_keys?(item) || (item.is_a?(Array) && item.all? do |entry|
          all_hashes_have_string_keys?(entry)
        end)
      end
    end

    def fail_with(message)
      raise ArgumentError, "invalid saved report: #{message}"
    end
  end
end

# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
