# frozen_string_literal: true

require_relative "test_helper"
require_relative "../benchmark/support/report_equivalence"

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class BenchmarkContractTest < Minitest::Test
  Comparator = BranchproofBenchmark::ReportEquivalence

  def test_only_enumerated_runtime_metadata_is_ignored
    before = report
    after = Marshal.load(Marshal.dump(before))
    after["run_ids"] = ["new-run"]
    after["run_metadata"]["captured_at"] = "later"
    after["run_metadata"]["project_root"] = "/candidate/fixture"
    after["source_inventory"]["root"] = "/candidate/fixture"
    after["source_inventory"]["sources"][0]["absolute_path"] = "/candidate/fixture/lib/policy.rb"
    after["observations"]["run_ids"] = ["new-run"]
    after["observations"]["executions"][0]["run_id"] = "new-run"
    after["observations"]["tests"][0]["source"]["path"] = "/candidate/fixture/spec/policy_spec.rb"

    assert Comparator.equivalent?({ "exit_status" => 0, "report" => before }, { "exit_status" => 0, "report" => after })
  end

  def test_semantic_changes_are_reported
    mutations = [
      ->(doc) { doc.fetch("report")["analysis"]["decisions"][0]["decision_id"] = "changed-decision" },
      ->(doc) { doc.fetch("report")["analysis"]["decisions"][0]["support_reason"] = "unsupported-source" },
      ->(doc) { doc.fetch("report")["analysis"]["decisions"][0]["decision_table"]["rules"][0]["id"] = "changed-rule" },
      ->(doc) { doc.fetch("report")["source_inventory"]["sources"][0]["source_id"] = "changed-source" },
      ->(doc) { doc.fetch("report")["observations"]["tests"][0]["id"] = "changed-test" },
      ->(doc) { doc.fetch("report")["observations"]["vectors"][0]["id"] = "changed-vector" },
      ->(doc) { doc.fetch("report")["observations"]["vectors"] << { "id" => "extra-vector" } },
      ->(doc) { doc.fetch("report")["metrics"]["vectors"] = 2 },
      ->(doc) { doc.fetch("report")["observations"]["vectors"][0]["test_ids"] = ["changed-owner"] },
      ->(doc) { doc.fetch("report")["observations"]["tests"][0]["phase_counts"]["body"] = 2 },
      ->(doc) { doc.fetch("report")["observations"]["tests"][0]["phases_by_test"]["body"] = 2 },
      ->(doc) { doc.fetch("report")["minima"][0]["status"] = "BEST_FOUND" },
      ->(doc) { doc.fetch("report")["minima"][0]["lower_bound"] = 2 },
      ->(doc) { doc.fetch("report")["minima"][0]["visited_nodes"] = 7 },
      ->(doc) { doc.fetch("report")["minima"][0]["selected_ids"] = ["other"] },
      ->(doc) { doc.fetch("report")["minima"][0]["necessary_ids"] = ["other"] },
      ->(doc) { doc.fetch("report")["minima"][0]["interchangeable_ids"] = ["other"] },
      ->(doc) { doc.fetch("report")["minima"][0]["additional_ids"] = ["other"] },
      ->(doc) { doc.fetch("report")["limits"]["exact_candidates"] = 4 },
      ->(doc) { doc.fetch("report")["diagnostics"][0]["code"] = "changed" },
      ->(doc) { doc.fetch("report")["completeness"]["analysis"] = false },
      ->(doc) { doc["exit_status"] = 1 }
    ]

    mutations.each do |mutation|
      changed = Marshal.load(Marshal.dump(artifact))
      mutation.call(changed)
      refute Comparator.equivalent?(artifact, changed)
    end
  end

  def test_ruby4_pipeline_smoke_writes_complete_reports_and_disjoint_timings
    Dir.mktmpdir("benchmark-contract") do |dir|
      artifacts = File.join(dir, "artifacts")
      fixtures = File.join(dir, "fixtures")
      stdout, stderr, status = run_pipeline(artifacts, fixtures)
      assert status.success?, "pipeline smoke failed: #{stderr}\n#{stdout}"

      rows = Dir[File.join(artifacts, "*.json")].map { |path| JSON.parse(File.read(path)) }
      assert_equal 6, rows.length
      assert(rows.all? { |row| row.fetch("report").fetch("analysis") })
      assert(rows.all? { |row| row.fetch("exit_status").zero? })

      candidate_artifacts = File.join(dir, "candidate-artifacts")
      _candidate_stdout, candidate_stderr, candidate_status = run_pipeline(candidate_artifacts, fixtures)
      assert candidate_status.success?, "candidate smoke failed: #{candidate_stderr}"
      assert Comparator.compare_directories(artifacts, candidate_artifacts),
             "baseline and candidate full reports differ"

      run_rows = stdout.lines.filter_map do |line|
        data = JSON.parse(line)
        data if data["type"] == "run"
      rescue JSON::ParserError
        nil
      end
      assert_equal 6, run_rows.length
      minimized_rows = run_rows.select { |row| row.fetch("level") == 3 }
      assert(minimized_rows.all? { |row| row.fetch("phases").key?("minimization") })
      assert(minimized_rows.all? { |row| row.fetch("phases").key?("minimizer_initialization") })
      assert minimized_rows.all? do |row|
        row.fetch("minimizer_by_scope").keys.sort == %w[local_vectors tests_scope_one_decision]
      end
      assert minimized_rows.all? do |row|
        row.fetch("minimizer_details").keys.sort == %w[greedy obligations search test_candidates vector_candidates]
      end
      assert(run_rows.all? do |row|
        case row.fetch("peak_process_rss_source")
        when "unavailable" then row.fetch("peak_process_rss_bytes").nil?
        when "getrusage" then row.fetch("peak_process_rss_bytes").positive?
        else false
        end
      end)
    end
  end

  def test_fixture_path_normalization_does_not_hide_test_id_changes
    after = Marshal.load(Marshal.dump(report))
    after["run_metadata"]["project_root"] = "/candidate/fixture"
    after["observations"]["tests"][0]["id"] = "changed-test-id"

    refute Comparator.equivalent?({ "exit_status" => 0, "report" => report }, { "exit_status" => 0, "report" => after })
  end

  def test_multiple_run_ids_are_rejected_instead_of_collapsed
    multiple_runs = artifact
    multiple_runs.fetch("report")["run_ids"] = %w[run-a run-b]

    refute Comparator.equivalent?(multiple_runs, multiple_runs)
  end

  def test_reports_from_directories_must_match_all_artifact_names_and_exit_status
    Dir.mktmpdir("benchmark-equivalence") do |dir|
      baseline = File.join(dir, "baseline")
      candidate = File.join(dir, "candidate")
      FileUtils.mkdir_p([baseline, candidate])
      File.write(File.join(baseline, "case.json"), JSON.generate(artifact))
      File.write(File.join(candidate, "case.json"), JSON.generate(artifact))

      assert_equal true, Comparator.compare_directories(baseline, candidate)
      Dir.chdir(dir) do
        assert Comparator.compare_directories("baseline", "candidate")
      end

      File.write(File.join(candidate, "case.json"), JSON.generate(artifact.merge("exit_status" => 1)))
      assert_equal false, Comparator.compare_directories(baseline, candidate)
    end
  end

  def report
    {
      "schema_version" => "1.4", "run_ids" => ["run-a"], "exit_status" => 0,
      "run_metadata" => { "captured_at" => "now", "project_root" => "/baseline/fixture" },
      "source_inventory" => { "root" => "/baseline/fixture",
                              "sources" => [{ "source_id" => "source-1", "absolute_path" => "/baseline/fixture/lib/policy.rb" }] },
      "observations" => {
        "run_ids" => ["run-a"], "executions" => [{ "run_id" => "run-a", "phase" => "body" }],
        "tests" => [{ "id" => "test-1", "source" => { "path" => "/baseline/fixture/spec/policy_spec.rb" },
                      "phase_counts" => { "body" => 1 }, "phases_by_test" => { "body" => 1 } }],
        "vectors" => [{ "id" => "vector-1", "test_ids" => ["test-1"] }]
      },
      "analysis" => { "decisions" => [{ "decision_id" => "decision-1",
                                        "decision_table" => { "rules" => [{ "id" => "rule-1" }] } }] },
      "metrics" => { "discovered" => 1, "vectors" => 1 },
      "limits" => { "exact_candidates" => 32 },
      "minima" => [{ "status" => "EXACT_MINIMUM", "lower_bound" => 1, "visited_nodes" => 1,
                     "selected_ids" => ["candidate-1"], "necessary_ids" => [],
                     "interchangeable_ids" => ["candidate-1"], "additional_ids" => [] }],
      "diagnostics" => [{ "code" => "warning" }],
      "completeness" => { "analysis" => true }
    }
  end

  def artifact
    { "exit_status" => 0, "report" => report }
  end

  def run_pipeline(artifacts, fixtures)
    Open3.capture3(
      { "SMOKE" => "1", "ARTIFACT_DIR" => artifacts, "PIPELINE_FIXTURE_DIR" => fixtures },
      RbConfig.ruby, "benchmark/pipeline.rb", chdir: File.expand_path("..", __dir__)
    )
  end
end
