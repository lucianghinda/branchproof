# frozen_string_literal: true

require "json"

module BranchproofBenchmark
  # Compares benchmark report artifacts while ignoring only explicitly known
  # run metadata. Report identities, evidence, phases, results and exit status
  # remain part of the comparison.
  module ReportEquivalence
    FIXTURE_ROOT = "<fixture-root>"
    CAPTURED_AT = "<captured-at>"
    RUN_ID = "<run-id>"

    module_function

    def equivalent?(baseline, candidate)
      return false unless artifact?(baseline) && artifact?(candidate)
      return false unless single_run?(baseline.fetch("report")) && single_run?(candidate.fetch("report"))

      normalize_artifact(baseline) == normalize_artifact(candidate)
    end

    def compare_directories(baseline_dir, candidate_dir)
      baseline_files = artifact_files(baseline_dir)
      candidate_files = artifact_files(candidate_dir)
      return false if baseline_files.empty? || baseline_files.keys != candidate_files.keys

      baseline_files.all? do |name, baseline_path|
        equivalent?(JSON.parse(File.read(baseline_path)), JSON.parse(File.read(candidate_files.fetch(name))))
      end
    rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES
      false
    end

    def normalize_artifact(artifact)
      normalized = deep_copy(artifact)
      report = normalized.fetch("report")
      root = report.dig("run_metadata", "project_root") || report.dig("source_inventory", "root")

      normalize_known_fields(report, root)
      normalized
    end

    def artifact?(value)
      value.is_a?(Hash) && value["exit_status"].is_a?(Integer) && value["report"].is_a?(Hash)
    end

    def single_run?(report)
      run_identifiers(report).uniq.length <= 1
    end

    def run_identifiers(report)
      values = []
      collect_run_identifiers(report, values)
      values.uniq
    end

    def collect_run_identifiers(value, identifiers)
      case value
      when Hash
        value.each do |key, item|
          identifiers.concat(run_id_values(key, item))
          collect_run_identifiers(item, identifiers)
        end
      when Array
        value.each { |item| collect_run_identifiers(item, identifiers) }
      end
    end

    def run_id_values(key, value)
      return [value] if key == "run_id" && value.is_a?(String) && !value.empty?
      return Array(value).select { |id| id.is_a?(String) && !id.empty? } if key == "run_ids"

      []
    end

    def normalize_known_fields(value, root)
      case value
      when Hash
        value.each { |key, item| value[key] = normalize_field(key, item, root) }
      when Array
        value.each { |item| normalize_known_fields(item, root) }
      end
    end

    # The explicit field allowlist keeps normalization narrow and auditable.
    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def normalize_field(key, item, root)
      return RUN_ID if key == "run_id" && item.is_a?(String) && !item.empty?
      return normalize_id_array(item) if key == "run_ids" && item.is_a?(Array)
      return CAPTURED_AT if key == "captured_at" && item.is_a?(String)
      return normalize_path(item, root) if fixture_path_field?(key)
      return item.map { |path| normalize_path(path, root) } if key == "load_paths" && item.is_a?(Array)

      normalize_known_fields(item, root)
      item
    end

    def normalize_id_array(ids)
      ids.map { |id| id.is_a?(String) && !id.empty? ? RUN_ID : id }
    end

    def fixture_path_field?(key)
      %w[project_root root absolute_path real_path path example_id].include?(key)
    end

    def normalize_path(value, root)
      return value unless value.is_a?(String) && root.is_a?(String) && !root.empty?
      return value unless value == root || value.start_with?("#{root}/")

      value.sub(root, FIXTURE_ROOT)
    end

    def artifact_files(directory)
      expanded_directory = File.expand_path(directory)
      Dir[File.join(expanded_directory, "**", "*.json")].to_h do |path|
        [path.delete_prefix("#{expanded_directory}/"), path]
      end
    end

    def deep_copy(value)
      case value
      when Hash then value.to_h { |key, item| [key, deep_copy(item)] }
      when Array then value.map { |item| deep_copy(item) }
      else value
      end
    end
    private_class_method :deep_copy
  end
end

if $PROGRAM_NAME == __FILE__
  unless ARGV.length == 2
    warn "usage: ruby benchmark/support/report_equivalence.rb BASELINE_DIR CANDIDATE_DIR"
    exit 2
  end

  equivalent = BranchproofBenchmark::ReportEquivalence.compare_directories(ARGV[0], ARGV[1])
  puts JSON.generate(equivalent: equivalent)
  exit(equivalent ? 0 : 1)
end
