# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

# rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

require "json"
# rubocop:disable-next Lint/RedundantRequireStatement -- supports standalone core entry
require "set"
require_relative "decision_table"

module Branchproof
  # Reads and validates a persisted JSON report without loading the project.
  class SavedReport
    SUPPORTED_SCHEMAS = %w[1.0 1.1 1.2 1.3].freeze
    STRICT_FLOW_SCHEMAS = %w[1.2 1.3].freeze
    DECISION_TABLE_STATUSES = %w[calculated not_calculated].freeze
    RULE_CONDITION_VALUES = DecisionTable::CONDITION_VALUES
    RULE_COVERAGE_STATUSES = DecisionTable::COVERAGE_STATUSES
    RULE_REACHABILITY_STATUSES = DecisionTable::REACHABILITY_STATUSES
    DECISION_KINDS = %w[boolean implicit multiway pattern exception].freeze
    NONBOOLEAN_KINDS = (DECISION_KINDS - ["boolean"]).freeze
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
      @schema_version = @document["schema_version"]
      schema = @schema_version
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
        kind = decision_kind(decision)
        fail_with("invalid decision kind") unless DECISION_KINDS.include?(kind)
        validate_string_field(decision, "context", nullable: true)
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
        alternatives = decision["alternatives"]
        if nonboolean_kind?(kind)
          fail_with("nonboolean decision tree must be null") unless decision.key?("tree") && decision["tree"].nil?
          validate_alternatives(alternatives)
        elsif alternatives && (!alternatives.is_a?(Array) || !alternatives.empty?)
          fail_with("boolean decision alternatives must be empty")
        end
      end
      @source_ids = source_ids
      @decision_ids = decision_ids
      @decisions_by_id = decisions.to_h { |decision| [decision["id"], decision] }
      @condition_ids = decisions.flat_map do |decision|
        Array(decision["conditions"]).map do |condition|
          condition["id"]
        end
      end
      fail_with("duplicate condition id") unless @condition_ids.uniq.length == @condition_ids.length
      @conditions_by_decision = decisions.to_h do |decision|
        [decision["id"], Array(decision["conditions"]).to_set { |condition| condition["id"] }]
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
      @alternative_counts = decisions.to_h do |decision|
        [decision["id"], nonboolean_kind?(decision_kind(decision)) ? decision.fetch("alternatives").length : 0]
      end
      @alternative_ids_by_decision = decisions.to_h do |decision|
        [decision["id"], if nonboolean_kind?(decision_kind(decision))
                           decision.fetch("alternatives").map do |alternative|
                             alternative["id"]
                           end
                         else
                           []
                         end]
      end
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
      @test_id_set = @test_ids.to_set
      tests.each { |test| validate_test(test) }
      vector_ids = unique_ids(vectors, "id", "vector")
      vectors.each do |vector|
        fail_with("invalid vector") unless hash_with_string_keys?(vector)
        fail_with("unknown vector decision") unless @decisions_by_id.key?(vector["decision_id"])
        decision = @decisions_by_id.fetch(vector["decision_id"])
        values = vector["values"]
        valid_values = values.is_a?(Array) && values.all? do |value|
          value.nil? || value == true || value == false
        end
        fail_with("vector values must be an array of booleans or null") unless valid_values
        expected_length = if @alternative_counts.fetch(vector["decision_id"]).positive?
                            @alternative_counts.fetch(vector["decision_id"])
                          else
                            @condition_counts.fetch(vector["decision_id"])
                          end
        fail_with("vector values do not match decision dimensions") unless values.length == expected_length
        fail_with("vector outcome must be boolean") unless [true, false].include?(vector["outcome"])
        validate_flow_vector(vector, decision) if strict_flow_decision?(decision)
        fail_with("unknown vector test") unless strings?(vector["test_ids"]) && vector["test_ids"].all? do |id|
          @test_id_set.include?(id)
        end
        validate_phases(vector)
        validate_integer_field(vector, "count")
        validate_integer_field(vector, "unattributed_count")
      end
      @vector_ids = vector_ids
      @vector_decision_by_id = vectors.to_h { |vector| [vector["id"], vector["decision_id"]] }
      @vectors_by_id = vectors.to_h { |vector| [vector["id"], vector] }
      @vectors_by_decision = vectors.group_by { |vector| vector["decision_id"] }
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
        fail_with("unknown analysis decision") unless @decisions_by_id.key?(id) && !seen.key?(id)
        seen[id] = true
        results = decision["condition_results"]
        fail_with("condition results must be an array") unless results.is_a?(Array)
        inventory_decision = @decisions_by_id[id]
        if nonboolean_kind?(decision_kind(inventory_decision))
          fail_with("nonboolean condition results must be empty") unless results.empty?
          validate_nonboolean_analysis(decision, inventory_decision)
        elsif decision.key?("decision_table")
          fail_with("decision tables are unsupported in legacy report schemas") unless @schema_version == "1.3"
          validate_decision_table(decision["decision_table"], inventory_decision)
        end
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
            @vectors_by_id.key?(id) && @vector_decision_by_id[id] == decision["decision_id"]
          end
          fail_with("canonical pair must reference vectors") unless valid_pair
        end
      end
    end

    # The persisted decision table must describe the same decision it was
    # derived from, so a saved report can be reported on and compared offline.
    def validate_decision_table(table, decision)
      fail_with("decision_table must be an object") unless hash_with_string_keys?(table)
      fail_with("decision_table status is invalid") unless DECISION_TABLE_STATUSES.include?(table["status"])
      fail_with("decision_table decision id mismatch") unless table["decision_id"] == decision["id"]
      %w[schema_version constraint_analysis_version].each do |field|
        fail_with("decision_table #{field} must be an integer") unless table[field].is_a?(Integer)
      end
      unless table["schema_version"] == DecisionTable::SCHEMA_VERSION
        fail_with("unsupported decision_table schema version")
      end
      solver_version = table["constraint_analysis_version"]
      supported_solver = [1, DecisionTable::CONSTRAINT_ANALYSIS_VERSION].include?(solver_version) &&
                         solver_version <= DecisionTable::CONSTRAINT_ANALYSIS_VERSION
      fail_with("unsupported decision_table constraint analysis version") unless supported_solver
      validate_string_field(table, "reason", nullable: true)
      unless DecisionTable::COVERAGE_SUMMARY_STATUSES.include?(table["coverage_status"])
        fail_with("invalid decision_table coverage status")
      end
      %w[generated_rules impossible_rules required_rules covered_rules missing_rules].each do |field|
        unless table[field].is_a?(Integer) && table[field] >= 0
          fail_with("decision_table #{field} must be a nonnegative integer")
        end
      end
      rules = table["rules"]
      fail_with("decision_table rules must be an array") unless rules.is_a?(Array)
      unique_ids(rules, "id", "decision table rule")
      indexes = rules.map { |rule| rule["index"] }
      fail_with("decision table rule indexes must be consecutive") unless indexes.sort == (0...rules.length).to_a
      condition_count = decision["conditions"].length
      rules.each { |rule| validate_decision_table_rule(rule, decision, condition_count) }
      validate_decision_table_counts(table, rules)
      validate_decision_table_summary(table, rules)
    end

    def validate_decision_table_rule(rule, decision, condition_count)
      fail_with("invalid decision table rule") unless hash_with_string_keys?(rule)
      validate_string_field(rule, "label")
      validate_integer_field(rule, "index")
      unless rule["index"].is_a?(Integer) && rule["index"] >= 0
        fail_with("decision table rule index must be nonnegative")
      end
      fail_with("decision table rule label does not match its index") unless rule["label"] == "R#{rule["index"] + 1}"
      conditions = rule["conditions"]
      valid = conditions.is_a?(Array) && conditions.length == condition_count &&
              conditions.all? { |value| RULE_CONDITION_VALUES.include?(value) }
      fail_with("decision table rule conditions do not match the decision") unless valid
      fail_with("decision table rule outcome must be boolean") unless [true, false].include?(rule["outcome"])
      expected_id = DecisionTable.rule_id(decision["id"], conditions, rule["outcome"])
      unless rule["id"] == expected_id
        fail_with("decision table rule id does not match its decision, conditions, and outcome")
      end
      fail_with("invalid decision table rule coverage") unless RULE_COVERAGE_STATUSES.include?(rule["coverage"])
      unless RULE_REACHABILITY_STATUSES.include?(rule["reachability"])
        fail_with("invalid decision table rule reachability")
      end
      validate_string_field(rule, "reachability_reason", nullable: true)
      if rule["reachability"] == "statically_impossible" && !rule["reachability_reason"].is_a?(String)
        fail_with("statically impossible rule requires a reason code")
      end
      if %w[observed unknown].include?(rule["reachability"]) && !rule["reachability_reason"].nil?
        fail_with("observed or unknown rule must not have a reachability reason")
      end
      fail_with("decision table rule tests must be strings") unless strings?(rule["tests"])
      fail_with("unknown decision table rule test") unless rule["tests"].all? { |id| @test_id_set.include?(id) }
      fail_with("decision table rule vector_ids must be strings") unless strings?(rule["vector_ids"])
      unless rule["vector_ids"].uniq.length == rule["vector_ids"].length
        fail_with("duplicate decision table rule vector")
      end
      fail_with("unknown decision table rule vector") unless rule["vector_ids"].all? do |id|
        @vector_decision_by_id[id] == decision["id"]
      end
      validate_decision_table_evidence(rule, decision)
      validate_integer_field(rule, "unattributed_count")
      unless rule["unattributed_count"].is_a?(Integer) && rule["unattributed_count"] >= 0
        fail_with("decision table rule unattributed count must be nonnegative")
      end
      return unless rule["coverage"] == "covered" && rule["vector_ids"].empty?

      fail_with("covered decision table rule requires evidence")
    end

    def validate_decision_table_counts(table, rules)
      if table["status"] == "not_calculated"
        fail_with("not_calculated decision table must not contain rules") unless rules.empty?
        %w[generated_rules impossible_rules required_rules covered_rules missing_rules].each do |field|
          fail_with("not_calculated decision table #{field} must be zero") unless table[field].zero?
        end
        return
      end

      fail_with("decision_table generated_rules mismatch") unless table["generated_rules"] == rules.length
      impossible = rules.count { |rule| rule["coverage"] == "excluded" }
      covered = rules.count { |rule| rule["coverage"] == "covered" }
      fail_with("decision_table impossible_rules mismatch") unless table["impossible_rules"] == impossible
      fail_with("decision_table required_rules mismatch") unless table["required_rules"] == rules.length - impossible
      fail_with("decision_table covered_rules mismatch") unless table["covered_rules"] == covered
      return if table["missing_rules"] == table["required_rules"] - table["covered_rules"]

      fail_with("decision_table missing_rules mismatch")
    end

    def validate_decision_table_summary(table, rules)
      if table["status"] == "not_calculated"
        allowed_reason = DecisionTable::NOT_CALCULATED_REASONS.include?(table["reason"])
        fail_with("not_calculated decision table requires a supported reason") unless allowed_reason
        expected_status = table["reason"] == "unsupported_decision" ? "unsupported" : "not_calculated"
        unless table["coverage_status"] == expected_status
          fail_with("not_calculated decision table coverage status mismatch")
        end
        fail_with("not_calculated decision table percentage must be null") unless table["percentage"].nil?
        unless table["reachability_analyzed"] == false
          fail_with("not_calculated decision table reachability must be false")
        end
        return
      end

      fail_with("calculated decision table reason must be null") unless table["reason"].nil?
      reachability_analyzed = table["reachability_analyzed"]
      unless [true, false].include?(reachability_analyzed)
        fail_with("decision_table reachability_analyzed must be boolean")
      end
      required = table["required_rules"]
      covered = table["covered_rules"]
      generated = table["generated_rules"]
      expected_status = DecisionTable.coverage_status(covered, required, generated)
      fail_with("decision_table coverage status mismatch") unless table["coverage_status"] == expected_status
      expected_percentage = DecisionTable.percentage(covered, required)
      fail_with("decision_table percentage mismatch") unless table["percentage"] == expected_percentage
      return unless table["reachability_analyzed"] == false

      fail_with("un-analyzed reachability cannot exclude rules") if rules.any? do |rule|
        rule["coverage"] == "excluded"
      end
      fail_with("un-analyzed reachability contains impossible rule") if rules.any? do |rule|
        rule["reachability"] == "statically_impossible"
      end
    end

    def validate_decision_table_evidence(rule, _decision)
      rule["vector_ids"].each do |vector_id|
        vector = @vectors_by_id.fetch(vector_id)
        matches = vector["outcome"] == rule["outcome"] && rule["conditions"].each_with_index.all? do |required, index|
          required == DecisionTable::DONT_CARE || vector["values"][index] == (required == DecisionTable::TRUE_VALUE)
        end
        fail_with("decision table rule evidence does not match its conditions and outcome") unless matches
      end
      expected_tests = rule["vector_ids"].flat_map { |id| @vectors_by_id.fetch(id)["test_ids"] }.uniq.sort
      fail_with("decision table rule tests do not match its evidence") unless rule["tests"].sort == expected_tests
      expected_unattributed = rule["vector_ids"].sum { |id| @vectors_by_id.fetch(id).fetch("unattributed_count", 0) }
      unless rule["unattributed_count"] == expected_unattributed
        fail_with("decision table rule unattributed count does not match its evidence")
      end
      if rule["coverage"] == "covered" && rule["reachability"] != "observed"
        fail_with("covered decision table rule requires observed reachability")
      end
      if rule["coverage"] == "excluded" && rule["reachability"] != "statically_impossible"
        fail_with("excluded decision table rule requires static impossibility")
      end
      if rule["coverage"] == "missing" && rule["reachability"] != "unknown"
        fail_with("missing decision table rule requires unknown reachability")
      end
      return unless %w[missing excluded].include?(rule["coverage"])

      fail_with("noncovered decision table rule must not contain evidence") unless rule["vector_ids"].empty? &&
                                                                                   rule["tests"].empty? &&
                                                                                   rule["unattributed_count"].zero?
    end

    def decision_kind(decision)
      kind = decision && decision["kind"]
      kind.nil? || kind.empty? ? "boolean" : kind
    end

    def nonboolean_kind?(kind)
      NONBOOLEAN_KINDS.include?(kind)
    end

    def validate_alternatives(alternatives)
      fail_with("alternatives must be an array") unless alternatives.is_a?(Array)
      ids = unique_ids(alternatives, "id", "alternative")
      alternatives.each do |alternative|
        fail_with("alternative index must be an integer") unless alternative["index"].is_a?(Integer)
        fail_with("alternative expression must be a string") unless alternative["expression"].is_a?(String)
        %w[line column byte_start byte_length].each do |field|
          validate_integer_field(alternative, field, nullable: true)
        end
      end
      indexes = alternatives.map { |alternative| alternative["index"] }
      fail_with("alternative indexes must be consecutive") unless indexes.sort == (0...alternatives.length).to_a
      ids
    end

    def validate_nonboolean_analysis(analysis_decision, inventory_decision)
      conditions = analysis_decision["conditions"]
      fail_with("nonboolean conditions must be empty") unless conditions.nil? || conditions == []
      coverage = analysis_decision["coverage"]
      if coverage.nil?
        return unless strict_flow_decision?(inventory_decision)

        fail_with("complete flow analysis requires coverage")
      end

      fail_with("flow coverage must be an object") unless hash_with_string_keys?(coverage)
      fail_with("alternative coverage must be an object") unless hash_with_string_keys?(coverage["alternative"])
      validate_alternative_coverage(coverage["alternative"], inventory_decision)
      mcdc = coverage["mcdc"]
      if mcdc.nil?
        fail_with("flow MC/DC status must be explicit") if strict_flow_decision?(inventory_decision)
        return
      end

      allowed = if inventory_decision["support_status"].to_s.upcase == "UNSUPPORTED"
                  %w[not_applicable unsupported]
                else
                  ["not_applicable"]
                end
      fail_with("nonboolean MC/DC must be not_applicable") unless hash_with_string_keys?(mcdc) &&
                                                                  allowed.include?(mcdc["status"])
    end

    def validate_alternative_coverage(coverage, decision)
      allowed_statuses = %w[covered partial unexecuted]
      allowed_statuses << "unsupported" if decision["support_status"].to_s.upcase == "UNSUPPORTED"
      fail_with("invalid alternative coverage status") unless allowed_statuses.include?(coverage["status"])
      %w[covered_alternatives required_alternatives].each do |field|
        validate_integer_field(coverage, field)
      end
      expected = decision.fetch("alternatives")
      expected_for_coverage = coverage["status"] == "unsupported" ? [] : expected
      if strict_flow_decision?(decision)
        %w[covered_alternatives required_alternatives].each do |field|
          fail_with("#{field} must be an integer") unless coverage[field].is_a?(Integer)
        end
      end
      unless coverage["required_alternatives"] == expected_for_coverage.length
        fail_with("alternative coverage count mismatch")
      end
      if strict_flow_decision?(decision)
        fail_with("alternative coverage count must be nonnegative") unless coverage["covered_alternatives"] >= 0 &&
                                                                           coverage["required_alternatives"] >= 0
        fail_with("covered alternatives exceed required alternatives") unless coverage["covered_alternatives"] <=
                                                                              coverage["required_alternatives"]
      end
      alternatives = coverage["alternatives"]
      fail_with("alternative coverage alternatives must be an array") unless alternatives.is_a?(Array)
      seen = {}
      alternatives.each do |row|
        fail_with("invalid alternative coverage row") unless hash_with_string_keys?(row)
        id = row["alternative_id"]
        inventory = expected_for_coverage.find { |alternative| alternative["id"] == id }
        fail_with("unknown alternative coverage id") unless inventory && !seen.key?(id)
        seen[id] = true
        unless row["index"].is_a?(Integer) && row["index"] == inventory["index"]
          fail_with("alternative coverage index mismatch")
        end
        fail_with("alternative coverage expression must be a string") unless row["expression"].is_a?(String)
        %w[selected not_selected skipped].each do |state|
          if strict_flow_decision?(decision)
            validate_alternative_evidence(row[state], decision, inventory["index"], state)
          else
            validate_alternative_evidence(row[state])
          end
        end
      end
      fail_with("alternative coverage missing rows") unless seen.keys.sort == expected_for_coverage.map { |alternative|
        alternative["id"]
      }.sort
      missing = coverage["missing_alternatives"]
      fail_with("missing alternatives must be an array of strings") unless strings?(missing)
      if strict_flow_decision?(decision)
        expected_missing = alternatives.filter_map do |row|
          row["alternative_id"] unless row.dig("selected", "observed")
        end
        fail_with("missing alternatives do not match selected evidence") unless missing.sort == expected_missing.sort
        covered = alternatives.count { |row| row.dig("selected", "observed") }
        unless coverage["covered_alternatives"] == covered
          fail_with("covered alternatives do not match selected evidence")
        end
        expected_status = if covered.zero?
                            "unexecuted"
                          elsif covered == expected.length
                            "covered"
                          else
                            "partial"
                          end
        fail_with("alternative coverage status does not match evidence") unless coverage["status"] == expected_status
      end
      fail_with("unknown missing alternative") unless (missing - expected.map do |alternative|
        alternative["id"]
      end).empty?
    end

    def validate_alternative_evidence(evidence, decision = nil, index = nil, state = nil)
      fail_with("alternative evidence must be an object") unless hash_with_string_keys?(evidence)
      fail_with("alternative evidence observed must be boolean") unless [true, false].include?(evidence["observed"])
      fail_with("alternative evidence vector_ids must be strings") unless strings?(evidence["vector_ids"])
      unless evidence["vector_ids"].uniq.length == evidence["vector_ids"].length
        fail_with("duplicate alternative evidence vector")
      end
      fail_with("unknown alternative evidence vector") unless evidence["vector_ids"].all? do |id|
        @vectors_by_id.key?(id)
      end
      fail_with("alternative evidence test_ids must be strings") unless strings?(evidence["test_ids"])
      unless evidence["test_ids"].uniq.length == evidence["test_ids"].length
        fail_with("duplicate alternative evidence test")
      end
      fail_with("unknown alternative evidence test") unless evidence["test_ids"].all? do |id|
        @test_id_set.include?(id)
      end
      validate_integer_field(evidence, "unattributed_count")
      return unless decision

      vectors = evidence["vector_ids"].map { |id| @vectors_by_id.fetch(id) }
      fail_with("alternative evidence references another decision") unless vectors.all? do |vector|
        vector["decision_id"] == decision["id"]
      end
      expected_value = lambda do |vector|
        value = vector["values"][index]
        if state == "selected"
          value == true
        else
          state == "not_selected" ? value == false : value.nil?
        end
      end
      fail_with("alternative evidence state mismatch") unless vectors.all?(&expected_value)
      decision_vectors = @vectors_by_decision.fetch(decision["id"], [])
      expected_vectors = decision_vectors.select(&expected_value)
      expected_vector_ids = expected_vectors.map { |vector| vector["id"] }.sort
      fail_with("alternative evidence is incomplete") unless evidence["vector_ids"].sort == expected_vector_ids
      expected_tests = vectors.flat_map { |vector| vector["test_ids"] }.uniq.sort
      fail_with("alternative evidence test owners mismatch") unless evidence["test_ids"].sort == expected_tests
      expected_unattributed = vectors.sum { |vector| vector.fetch("unattributed_count", 0).to_i }
      fail_with("alternative evidence unattributed count mismatch") unless evidence.fetch("unattributed_count",
                                                                                          0) == expected_unattributed
      fail_with("alternative evidence observed mismatch") unless evidence["observed"] == !vectors.empty?
    end

    def validate_flow_vector(vector, decision)
      values = vector["values"]
      valid = if decision_kind(decision) == "implicit"
                vector["outcome"] == true && values.length == 2 && values.all? do |value|
                  [true, false].include?(value)
                end && values.count(true) == 1
              else
                observations = values.each_with_index.filter_map { |value, index| [index, value] unless value.nil? }
                vector["outcome"] == true &&
                  observations.any? &&
                  observations.each_with_index.all? do |(index, value), position|
                    index == position && value == (position == observations.length - 1)
                  end
              end
      fail_with("invalid flow vector trace") unless valid
    end

    def strict_flow_decision?(decision)
      STRICT_FLOW_SCHEMAS.include?(@schema_version) &&
        nonboolean_kind?(decision_kind(decision)) &&
        decision["support_status"].to_s.upcase != "UNSUPPORTED"
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
        @test_id_set.include?(test_id) && strings?(values) && values.all? { |phase| valid_phases.include?(phase) }
      end
      fail_with("invalid phases_by_test") unless valid
    end

    def validate_test(test)
      %w[adapter name class_name method_name source_path example_id].each do |field|
        validate_string_field(test, field, nullable: true)
      end
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

      analysis_by_id = analysis["decisions"].to_h { |decision| [decision["decision_id"], decision] }
      @supported_ids.each do |id|
        inventory_decision = @decisions_by_id.fetch(id)
        analysis_decision = analysis_by_id[id]
        if strict_flow_decision?(inventory_decision)
          fail_with("complete analysis is missing flow decision") unless analysis_decision
          validate_nonboolean_analysis(analysis_decision, inventory_decision)
        end
        actual = Array(analysis_decision && analysis_decision["condition_results"]).map do |result|
          result["condition_id"]
        end.sort
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
      nullable_string_fields = %w[framework framework_version rspec_rails_version rails_version]
      nullable_string_fields.each do |field|
        fail_with("run_metadata #{field} must be a string") if metadata.key?(field) &&
                                                               !metadata[field].nil? && !metadata[field].is_a?(String)
      end
      array_fields = %w[source_patterns test_patterns test_files runner_args selected_test_files selected_example_ids]
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
        @test_id_set.include?(test_id) && hash_with_string_keys?(location) &&
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

# rubocop:enable Metrics/BlockLength
