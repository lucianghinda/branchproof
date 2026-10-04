# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity

require "digest"
require "json"
require "pathname"
require "stringio"
require_relative "evidence"
require_relative "saved_report"
require_relative "analyzer"
require_relative "minimizer"
require_relative "report"

module Branchproof
  # Reconstructs one analysis from validated, offline report artifacts.
  class Collation
    SCHEMA_VERSIONS = %w[1.4 1.5 1.6].freeze
    STATUS_ORDER = %w[passed skipped unknown failed].freeze

    def initialize(inputs:, expected_shards: nil)
      raise ArgumentError, "inputs must be a non-empty Array" unless inputs.is_a?(Array) && !inputs.empty?
      if !expected_shards.nil? && (!expected_shards.is_a?(Array) || expected_shards.empty? ||
                                   !expected_shards.all? { |id| nonempty_string?(id) } ||
                                   expected_shards.uniq.length != expected_shards.length)
        raise ArgumentError, "expected_shards must be a non-empty array of unique IDs or nil"
      end

      @inputs = inputs
      @expected_shards = expected_shards&.dup
    end

    def call
      shards = validated_shards
      unique_shards = unique_artifacts(shards).sort_by { |shard| [shard.fetch(:id), shard.fetch(:digest)] }
      reference = unique_shards.first
      validate_compatibility!(unique_shards, reference)
      validate_union_storage!(unique_shards, reference.fetch(:limits))
      evidence = merged_evidence(unique_shards, reference)
      missing = @expected_shards ? @expected_shards - unique_shards.map { |shard| shard.fetch(:id) } : []
      collection_status = if @expected_shards.nil?
                            "unknown"
                          elsif missing.empty?
                            "complete"
                          else
                            "incomplete"
                          end
      baseline, failed_or_error = merged_baseline(unique_shards, collection_status)
      analysis = if failed_or_error
                   nil
                 else
                   Analyzer.new(inventory: reference.fetch(:inventory), evidence: evidence,
                                limits: reference.fetch(:limits), reachability: reference.fetch(:reachability)).call
                 end
      analysis = Marshal.load(Marshal.dump(analysis)) if analysis
      completeness = effective_completeness(unique_shards, evidence, analysis, collection_status)
      analysis[:completeness] = analysis.fetch(:completeness).merge(completeness) if analysis
      evidence[:completeness] = completeness
      evidence[:run_ids] = evidence.fetch(:run_ids).sort
      minima = analysis ? calculated_minima(analysis, evidence, reference) : []
      report = build_report(reference, evidence, analysis, minima, baseline, unique_shards, missing,
                            collection_status)
      validate_output!(report)
    end

    private

    def validated_shards
      ids = {}
      @inputs.map do |input|
        raise ArgumentError, "each input must be an object" unless input.is_a?(Hash)

        document = stringify(input[:document] || input["document"])
        raise ArgumentError, "input document must be an object" unless document.is_a?(Hash)

        SavedReport.new(document).validate!
        schema = document.fetch("schema_version")
        unless SCHEMA_VERSIONS.include?(schema)
          raise ArgumentError,
                "collation accepts raw report schemas 1.4 through 1.6"
        end

        digest = Digest::SHA256.hexdigest(canonical_json(document))
        path = input[:path] || input["path"]
        raise ArgumentError, "input path must be a string" unless path.is_a?(String)

        id = input[:id] || input["id"]
        id = digest if id.nil? && @expected_shards.nil?
        raise ArgumentError, "input shard ID is required" unless nonempty_string?(id)
        raise ArgumentError, "unexpected shard ID #{id.inspect}" if @expected_shards && !@expected_shards.include?(id)
        raise ArgumentError, "duplicate shard ID #{id.inspect}" if ids.key?(id) && ids[id] != digest

        ids[id] = digest
        metadata = document["run_metadata"]
        validate_reconstruction_metadata!(document, metadata)
        validate_baseline_tests!(document, metadata)
        {
          id: id, path: path, paths: [path], document: document, digest: digest,
          run_ids: document.fetch("run_ids"), inventory: symbolize(document.fetch("source_inventory")),
          snapshot: document.fetch("observations"), baseline: document.fetch("baseline"),
          completeness: effective_input_completeness(document), metadata: metadata,
          limits: Limits.normalize(metadata.fetch("limits")), level: metadata.fetch("requested_level"),
          reachability: metadata.fetch("reachability"), minimum: document.dig("coverage_policy", "minimum"),
          changed_scope: document["changed_scope"],
          minimum_changed: document.dig("changed_coverage_policy", "minimum_changed") || {}
        }
      end
    end

    def validate_reconstruction_metadata!(document, metadata)
      raise ArgumentError, "collation requires run_metadata" unless metadata.is_a?(Hash)

      unless [1, 2, 3].include?(metadata["requested_level"])
        raise ArgumentError, "collation requires requested_level 1, 2, or 3"
      end
      unless [true, false].include?(metadata["reachability"])
        raise ArgumentError, "collation requires Boolean reachability metadata"
      end

      limits = metadata["limits"]
      valid_limits = limits.is_a?(Hash) && limits.keys.sort == Limits::KEYS.map(&:to_s).sort &&
                     limits.values.all? { |value| value.is_a?(Integer) && value.positive? }
      raise ArgumentError, "collation requires complete limits metadata" unless valid_limits
      raise ArgumentError, "collation requires project and framework metadata" unless
        nonempty_string?(metadata["project_kind"]) && nonempty_string?(metadata["project_root"]) &&
        nonempty_string?(metadata["framework"])
      raise ArgumentError, "collation requires a current Branchproof version" unless
        document["tool_version"] == Branchproof::VERSION
      raise ArgumentError, "collation requires the current criterion version" unless
        document["criterion_version"] == Evidence::CRITERION_VERSION
      raise ArgumentError, "collation requires the current Ruby runtime" unless document["runtime"] == RUBY_DESCRIPTION
      unless document["coverage_policy"].is_a?(Hash) &&
             document["coverage_policy"]["minimum"].is_a?(Hash)
        raise ArgumentError,
              "collation requires complete policy metadata"
      end

      run_ids = document["run_ids"]
      unless run_ids.is_a?(Array) && !run_ids.empty? && run_ids.all? { |id| nonempty_string?(id) } &&
             run_ids.uniq.length == run_ids.length && document.dig("observations", "run_ids") == run_ids
        raise ArgumentError, "collation requires matching nonempty report and observation run IDs"
      end

      validate_baseline_counts!(document.fetch("baseline"))
      if %w[1.5 1.6].include?(document["schema_version"]) && !document["changed_scope"].is_a?(Hash)
        raise ArgumentError, "collation requires changed scope metadata"
      end
      return unless document["schema_version"] == "1.6"

      raise ArgumentError, "collation requires changed policy metadata" unless
        document["changed_coverage_policy"].is_a?(Hash) &&
        document["changed_coverage_policy"]["minimum_changed"].is_a?(Hash)
    end

    def validate_baseline_counts!(baseline)
      unless %w[PASSED FAILED ERROR INCOMPLETE].include?(baseline["status"])
        raise ArgumentError, "baseline status is unsupported for collation"
      end

      %w[executed_tests failed_tests skipped_tests].each do |field|
        value = baseline[field]
        raise ArgumentError, "baseline #{field} must be a nonnegative integer" unless value.is_a?(Integer) && value >= 0
      end
      raise ArgumentError, "baseline failed and skipped counts exceed executed tests" if
        baseline.fetch("failed_tests") + baseline.fetch("skipped_tests") > baseline.fetch("executed_tests")

      passed_with_failures = baseline.fetch("failed_tests").positive?
      zero_test_pass = baseline.fetch("executed_tests").zero?
      return unless baseline["status"] == "PASSED" && (passed_with_failures || zero_test_pass)

      raise ArgumentError, "PASSED baseline cannot contain failures or zero tests"
    end

    def validate_baseline_tests!(document, metadata)
      baseline_tests = document.dig("baseline", "tests")
      observations_list = document.dig("observations", "tests")
      observations = observations_list.to_h { |test| [test.fetch("id"), test] }
      baseline_by_id = Array(baseline_tests).to_h { |test| [test.fetch("id"), test] }
      baseline_by_id.each do |id, test|
        observed = observations[test.fetch("id")]
        next unless observed

        unless normalized_test_identity(test, metadata["project_root"]) ==
               normalized_test_identity(observed, metadata["project_root"])
          raise ArgumentError, "baseline test identity differs from observation for #{id.inspect}"
        end
        if test.fetch("status") != observed.fetch("status")
          raise ArgumentError, "baseline test status differs from observation for #{id.inspect}"
        end
      end

      statuses = observations_list.map { |test| test.fetch("status") }
      invalid = statuses - %w[passed failed skipped unknown running]
      unless invalid.empty?
        raise ArgumentError,
              "observed tests contain unsupported statuses: #{invalid.uniq.join(", ")}"
      end

      baseline = document.fetch("baseline")
      observed_failed = statuses.count("failed")
      observed_skipped = statuses.count("skipped")
      if observed_failed > baseline.fetch("failed_tests") || observed_skipped > baseline.fetch("skipped_tests")
        raise ArgumentError, "observed test failures or skips exceed baseline counts"
      end
      if baseline.fetch("status") == "PASSED" && statuses.any? { |status| !%w[passed skipped].include?(status) }
        raise ArgumentError, "PASSED baseline cannot contain failed, unknown, or running observed tests"
      end
    end

    def unique_artifacts(shards)
      by_digest = {}
      by_run = {}
      shards.each do |shard|
        if (prior = by_digest[shard.fetch(:digest)])
          if prior.fetch(:id) != shard.fetch(:id)
            raise ArgumentError, "the same report artifact cannot satisfy two shard IDs"
          end

          prior[:paths] |= shard.fetch(:paths)
          next
        end
        shard.fetch(:run_ids).each do |run_id|
          if (prior = by_run[run_id])
            raise ArgumentError, "conflicting run-ID overlap between #{prior.inspect} and #{shard.fetch(:id).inspect}"
          end

          by_run[run_id] = shard.fetch(:id)
        end
        by_digest[shard.fetch(:digest)] = shard
      end
      by_digest.values
    end

    def validate_compatibility!(shards, reference)
      semantic_inventory = semantic(reference.fetch(:inventory))
      keys = %i[limits level reachability minimum minimum_changed changed_scope]
      shards.drop(1).each do |shard|
        raise ArgumentError, "source inventories differ" unless semantic(shard.fetch(:inventory)) == semantic_inventory

        keys.each do |key|
          raise ArgumentError, "shard #{key} settings differ" unless shard.fetch(key) == reference.fetch(key)
        end
        %w[schema_version tool_version criterion_version runtime].each do |key|
          raise ArgumentError, "shard #{key} metadata differs" unless shard.fetch(:document).fetch(key) ==
                                                                      reference.fetch(:document).fetch(key)
        end
        %w[project_kind framework framework_version rspec_rails_version rails_version].each do |key|
          next if reference.fetch(:metadata)[key] == shard.fetch(:metadata)[key]

          raise ArgumentError, "shard #{key} metadata differs"
        end
      end
    end

    def merged_evidence(shards, reference)
      run_ids = shards.flat_map { |shard| shard.fetch(:run_ids) }
      raise ArgumentError, "run IDs must be unique across shards" unless run_ids.uniq.length == run_ids.length

      first_run_id = run_ids.first
      merger = Evidence.new(inventory: reference.fetch(:inventory), limits: reference.fetch(:limits),
                            run_id: first_run_id)
      shards.each do |shard|
        result = merger.merge(snapshot: shard.fetch(:snapshot))
        raise ArgumentError, "cannot merge shard evidence: #{result[:reason]}" unless result[:status] == "merged"
      end
      snapshot = symbolize(merger.snapshot)
      normalize_repeated_tests!(snapshot, shards)
      snapshot
    end

    def validate_union_storage!(shards, limits)
      tests = shards.flat_map { |shard| shard.fetch(:snapshot).fetch("tests").map { |test| test.fetch("id") } }.uniq
      raise ArgumentError, "collation union exceeds tests_per_run limit (#{limits[:tests_per_run]})" if
        tests.length > limits[:tests_per_run]

      vectors = shards.flat_map { |shard| shard.fetch(:snapshot).fetch("vectors") }.uniq { |vector| vector.fetch("id") }
      vectors_by_decision = vectors.group_by { |vector| vector.fetch("decision_id") }
      overfull = vectors_by_decision.find { |_decision, items| items.length > limits[:vectors_per_decision] }
      if overfull
        raise ArgumentError,
              "collation union exceeds vectors_per_decision limit (#{limits[:vectors_per_decision]})"
      end
      owners = vectors.sum do |vector|
        Array(vector["test_ids"]).uniq.length + (vector.fetch("unattributed_count", 0).positive? ? 1 : 0)
      end
      return unless owners > limits[:owner_associations_per_run]

      raise ArgumentError,
            "collation union exceeds owner_associations_per_run limit (#{limits[:owner_associations_per_run]})"
    end

    def effective_input_completeness(document)
      sections = [document.fetch("completeness"), document.dig("observations", "completeness")]
      sections << document.dig("analysis", "completeness") if document["analysis"].is_a?(Hash)
      %w[observation attribution analysis].to_h do |field|
        [field, sections.all? { |section| section.is_a?(Hash) && section[field] == true }]
      end
    end

    def effective_completeness(shards, evidence, analysis, collection_status)
      input_complete = %w[observation attribution analysis].to_h do |field|
        [field, shards.all? { |shard| shard.fetch(:completeness).fetch(field) }]
      end
      evidence_complete = symbolize(evidence.fetch(:completeness))
      analysis_complete = analysis ? symbolize(analysis.fetch(:completeness)) : {}
      result = %i[observation attribution analysis].to_h do |field|
        [field, input_complete.fetch(field.to_s) && evidence_complete[field] == true &&
          (!analysis || analysis_complete[field] == true)]
      end
      result[:observation] = false unless collection_status == "complete"
      result
    end

    def normalize_repeated_tests!(snapshot, shards)
      by_id = {}
      locations = {}
      shards.each do |shard|
        symbolize(shard.fetch(:metadata)["test_locations"] || {}).each do |id, location|
          if locations.key?(id) && locations[id] != location
            raise ArgumentError, "conflicting test location for #{id.inspect}"
          end

          locations[id] = location
        end
        shard.fetch(:snapshot).fetch("tests").each do |raw|
          test = symbolize(raw)
          id = test.fetch(:id).to_s
          if (prior_entry = by_id[id])
            prior = prior_entry.fetch(:test)
            unless test_identity(prior, prior_entry.fetch(:shard)) == test_identity(test, shard)
              raise ArgumentError, "conflicting test identity for #{id.inspect}"
            end

            prior[:status] = worse_status(prior[:status], test[:status])
          else
            by_id[id] = { test: test, shard: shard }
          end
        end
      end
      snapshot[:tests].each do |test|
        test[:status] = by_id.fetch(test.fetch(:id).to_s).fetch(:test).fetch(:status)
      end
    end

    def test_identity(test, shard)
      normalized_test_identity(test, shard.fetch(:metadata)["project_root"])
    end

    def normalized_test_identity(test, root)
      identity = symbolize(test).except(:status, :phase_counts)
      source = identity[:source]
      if source.is_a?(Hash) && source[:path].is_a?(String)
        absolute = File.expand_path(source[:path])
        expanded_root = File.expand_path(root.to_s)
        prefix = "#{expanded_root}#{File::SEPARATOR}"
        source[:path] = normalized_path(absolute, prefix, expanded_root)
      end
      if identity[:source_path].is_a?(String)
        absolute = File.expand_path(identity[:source_path])
        expanded_root = File.expand_path(root.to_s)
        prefix = "#{expanded_root}#{File::SEPARATOR}"
        identity[:source_path] = normalized_path(absolute, prefix, expanded_root)
      end
      identity
    end

    def normalized_path(absolute, prefix, root)
      return absolute unless absolute.start_with?(prefix)

      Pathname.new(absolute).relative_path_from(Pathname.new(root)).to_s
    end

    def worse_status(left, right)
      left_status = STATUS_ORDER.include?(left.to_s) ? left.to_s : "unknown"
      right_status = STATUS_ORDER.include?(right.to_s) ? right.to_s : "unknown"
      STATUS_ORDER[[STATUS_ORDER.index(left_status), STATUS_ORDER.index(right_status)].max]
    end

    def merged_baseline(shards, collection_status)
      baselines = shards.map { |shard| shard.fetch(:baseline) }
      failed = baselines.sum { |baseline| baseline.fetch("failed_tests", 0) }
      skipped = baselines.sum { |baseline| baseline.fetch("skipped_tests", 0) }
      executed = baselines.sum { |baseline| baseline.fetch("executed_tests", 0) }
      error = baselines.any? { |baseline| baseline["status"] == "ERROR" }
      failed_status = baselines.any? { |baseline| baseline["status"] == "FAILED" } || failed.positive?
      incomplete = collection_status != "complete" || baselines.any? do |baseline|
        baseline["status"] == "INCOMPLETE" || baseline["finalized"] != true
      end || shards.any? { |shard| shard.fetch(:completeness).values.any?(&:!) }
      status = if error
                 "ERROR"
               elsif incomplete
                 "INCOMPLETE"
               elsif failed_status
                 "FAILED"
               else
                 "PASSED"
               end
      all_tests = shards.flat_map { |shard| shard.fetch(:snapshot).fetch("tests") }
      summarized = all_tests.group_by { |test| test.fetch("id") }.map do |_id, records|
        first = symbolize(records.first)
        first[:status] = records.map { |record| record.fetch("status") }.reduce { |a, b| worse_status(a, b) }
        first[:phase_counts] = records.map { |record| symbolize(record).fetch(:phase_counts, {}) }
                                      .reduce({}) { |acc, counts| acc.merge(counts) { |_key, a, b| a.to_i + b.to_i } }
        first
      end
      baseline = { status: status, finalized: status != "ERROR" && status != "INCOMPLETE",
                   executed_tests: executed, failed_tests: failed, skipped_tests: skipped, tests: summarized }
      [baseline, error || failed_status]
    end

    def calculated_minima(analysis, evidence, reference)
      return [] if reference.fetch(:level) < 2

      ids = Array(reference.fetch(:inventory)[:decisions]).map { |decision| decision[:id] }
      minimizer = Minimizer.new(analysis: analysis, evidence: evidence, limits: reference.fetch(:limits))
      result = ids.filter_map { |id| minimizer.call(objective: :vectors, decision_ids: [id]) }
      result += ids.filter_map { |id| minimizer.call(objective: :tests, decision_ids: [id]) }
      result << minimizer.call(objective: :tests, decision_ids: ids)
      result
    end

    def build_report(reference, evidence, analysis, minima, baseline, shards, missing, collection_status)
      diagnostics = shards.flat_map do |shard|
        Array(shard.fetch(:document)["diagnostics"]).map { symbolize(_1) }
      end
      unless collection_status == "complete"
        diagnostics << { code: "collation_incomplete", severity: "warning",
                         message: "collection status is #{collection_status}" }
      end
      metadata = aggregate_metadata(shards)
      baseline[:diagnostics] = diagnostics
      report = Report.new(inventory: reference.fetch(:inventory), evidence: evidence, analysis: analysis,
                          minima: minima, baseline: baseline, diagnostics: diagnostics,
                          level: reference.fetch(:level), run_metadata: metadata,
                          changed_scope: reference.fetch(:changed_scope),
                          minimum: reference.fetch(:minimum), minimum_changed: reference.fetch(:minimum_changed))
      output = StringIO.new
      report.write(io: output, format: :json)
      document = JSON.parse(output.string)
      document["schema_version"] = "1.7"
      document["run_ids"] = shards.flat_map { |shard| shard.fetch(:run_ids) }.sort
      document["collation"] = {
        "version" => "1.0", "collection_status" => collection_status,
        "expected_shards" => @expected_shards, "missing_shards" => missing,
        "shards" => shards.map { |shard| provenance(shard) }
      }
      document
    end

    def aggregate_metadata(shards)
      metadata = symbolize(shards.first.fetch(:metadata))
      %w[source_patterns exclude_patterns test_patterns test_files selected_test_files selected_example_ids
         selected_source_files excluded_files].each do |field|
        values = shards.flat_map { |shard| Array(shard.fetch(:metadata)[field]) }
        metadata[field.to_sym] = values.uniq.sort unless values.empty?
      end
      metadata[:test_locations] = shards.each_with_object({}) do |shard, locations|
        locations.merge!(symbolize(shard.fetch(:metadata)["test_locations"] || {}))
      end.sort.to_h
      metadata[:seed] = nil
      metadata[:runner_args] = []
      %w[project_root captured_at].each do |field|
        values = shards.map { |shard| shard.fetch(:metadata)[field] }.uniq
        metadata[field.to_sym] = values.one? ? values.first : "multiple"
      end
      metadata
    end

    def provenance(shard)
      { "id" => shard.fetch(:id), "paths" => shard.fetch(:paths).sort,
        "report_digest" => shard.fetch(:digest), "run_ids" => shard.fetch(:run_ids).sort,
        "baseline" => shard.fetch(:baseline).slice(
          "status", "executed_tests", "failed_tests", "skipped_tests", "finalized"
        ),
        "completeness" => shard.fetch(:completeness), "run_metadata" => shard.fetch(:metadata) }
    end

    def validate_output!(document)
      SavedReport.new(document).validate!
    end

    def semantic(inventory)
      data = stringify(inventory)
      data.delete("root")
      Array(data["source_units"]).each do |unit|
        unit.delete("absolute_path")
        unit.delete("real_path")
      end
      data
    end

    def symbolize(value)
      case value
      when Hash then value.to_h { |key, item| [key.to_sym, symbolize(item)] }
      when Array then value.map { symbolize(_1) }
      else value
      end
    end

    def stringify(value)
      case value
      when Hash then value.to_h { |key, item| [key.to_s, stringify(item)] }
      when Array then value.map { stringify(_1) }
      else value
      end
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { canonical(_1) }
      else value
      end
    end

    def nonempty_string?(value)
      value.is_a?(String) && !value.empty?
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
