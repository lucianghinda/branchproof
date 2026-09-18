# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class TestRubyConstructAcceptance < Minitest::Test
  FIXTURES = File.expand_path("fixtures/ruby_constructs", __dir__).freeze
  GEM_ROOT = File.expand_path("..", __dir__).freeze
  EXECUTABLE = File.join(GEM_ROOT, "exe", "branchproof").freeze

  REPRESENTATIVE_CASES = {
    "IF-01" => { context: "if", kind: "boolean" },
    "IF-03" => { context: "elsif", kind: "boolean" },
    "IF-05" => { context: "unless", kind: "boolean" },
    "IF-08" => { context: "ternary", kind: "boolean" },
    "LOG-01" => { context: "short_circuit", kind: "boolean" },
    "LOOP-01" => { context: "while", kind: "boolean" },
    "LOOP-02" => { context: "until", kind: "boolean" },
    "CASE-01" => { context: "case", kind: "multiway" },
    "CASE-06" => { context: "case_when", kind: "boolean" },
    "PAT-01" => { context: "case_in", kind: "pattern" },
    "PAT-05" => { context: "pattern_guard", kind: "boolean" },
    "PAT-03" => { context: "pattern_in", kind: "boolean" },
    "ASGN-01" => { context: "or_assignment", kind: "implicit" },
    "ASGN-02" => { context: "and_assignment", kind: "implicit" },
    "NIL-01" => { context: "safe_navigation", kind: "implicit" }
  }.freeze

  def test_serial_cli_attributes_representative_construct_corpus
    REPRESENTATIVE_CASES.each do |id, expected|
      result = run_fixture(id)
      assert_equal 0, result[:status].exitstatus, "#{id}: #{result[:stderr]}"
      report = result.fetch(:json)
      assert_equal "PASSED", report.dig("baseline", "status"), id
      assert_operator report.dig("baseline", "executed_tests"), :>=, 1

      decisions = report.fetch("source_inventory").fetch("decisions")
      assert_includes decisions.map { |decision| [decision["context"], decision["kind"]] },
                      [expected[:context], expected[:kind]], id
      decision = decisions.find { |item| item.values_at("context", "kind") == expected.values_at(:context, :kind) }
      row = report.fetch("analysis").fetch("decisions").find { |item| item.fetch("decision_id") == decision.fetch("id") }
      refute_nil row, id
      if expected[:kind] == "boolean"
        %w[decision condition condition_decision mcdc].each do |criterion|
          assert_equal "covered", row.dig("coverage", criterion, "status"), "#{id}: #{criterion}"
        end
        assert_equal "covered", row.dig("decision_table", "coverage_status"), id
      else
        assert_equal "covered", row.dig("coverage", "alternative", "status"), id
        assert_equal decision.fetch("alternatives").length, row.dig("coverage", "alternative", "covered_alternatives"), id
        assert_equal "not_applicable", row.dig("coverage", "mcdc", "status"), id
      end
      if id == "PAT-05"
        outer = decisions.find { |item| item.fetch("context") == "case_in" }
        assert_equal "UNSUPPORTED", outer.fetch("support_status")
        assert_equal ["unsupported_pattern_guard"], outer.fetch("support_reasons")
      end

      tests = report.dig("observations", "tests")
      refute_empty tests, id
      assert tests.any? { |test| test.fetch("method_name").include?("test_construct_cases") }, id
      vectors = report.dig("observations", "vectors").select { |vector| vector.fetch("decision_id") == decision.fetch("id") }
      refute_empty vectors, id
      owners = tests.map { |test| test.fetch("id") }
      vectors.each { |vector| assert_equal owners, vector.fetch("test_ids"), id }
    end
  end

  def test_attribution_and_lifecycle_include_setup_body_and_teardown
    result = run_fixture("IF-03", test_source: <<~RUBY)
      class ConstructLifecycleTest < Minitest::Test
        def setup
          example(true, true)
          super
        end

        def teardown
          super
          example(false, false)
        end

        def test_construct_cases
          assert_equal "first", example(true, true)
          assert_equal "second", example(false, true)
          assert_equal "neither", example(false, false)
        end

      end
    RUBY

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    report = result.fetch(:json)
    test = report.dig("observations", "tests").find { |item| item.fetch("method_name").include?("test_construct_cases") }
    refute_nil test
    assert_equal 1, test.dig("phase_counts", "setup")
    assert_equal 1, test.dig("phase_counts", "body")
    assert_equal 1, test.dig("phase_counts", "teardown")
    phases = report.dig("observations", "vectors").flat_map { |vector| vector.fetch("phases_by_test").values.flatten }
    assert_includes phases, "setup"
    assert_includes phases, "body"
    assert_includes phases, "teardown"
  end

  def test_one_serial_run_can_be_reopened_offline_and_levels_have_parity
    reports = [1, 2, 3].map do |level|
      result = run_fixture("IF-01", level: level, output: "report-#{level}.json")
      assert_equal 0, result[:status].exitstatus, "level #{level}: #{result[:stderr]}"
      assert_equal ["once\n"], result.fetch(:execution_lines)
      result.fetch(:output_json)
    end

    reports.each_cons(2) do |first, second|
      assert_equal first.fetch("analysis").fetch("coverage"), second.fetch("analysis").fetch("coverage")
    end

    Dir.mktmpdir("branchproof-construct-offline-") do |root|
      report_path = File.join(root, "report.json")
      File.write(report_path, JSON.generate(reports.last))
      assert_equal "1.3", Branchproof::SavedReport.read(report_path).fetch("schema_version")
      output, error, status = Open3.capture3(RbConfig.ruby, EXECUTABLE, "report", report_path, "--view", "decisions")
      assert status.success?, error
      assert_includes output, "Coverage ladder"
    end
  end

  def test_failed_and_incomplete_serial_runs_have_distinct_cli_contracts
    failed = run_fixture("IF-01", test_source: <<~RUBY)
      class ConstructFailureTest < Minitest::Test
        def test_construct_cases
          flunk "intentional corpus failure"
        end
      end
    RUBY
    assert_equal 1, failed[:status].exitstatus, failed[:stderr]
    assert_equal "FAILED", failed.dig(:json, "baseline", "status")
    assert_equal 1, failed.dig(:json, "baseline", "failed_tests")

    incomplete = run_fixture("IF-01", test_source: "")
    assert_equal 2, incomplete[:status].exitstatus, incomplete[:stderr]
    assert_equal "INCOMPLETE", incomplete.dig(:json, "baseline", "status")
    assert_equal 0, incomplete.dig(:json, "baseline", "executed_tests")
  end

  def test_no_decision_fixture_has_a_passed_baseline_and_analysis_exit_two
    result = run_fixture("ARG-01")
    assert_equal 2, result[:status].exitstatus, result[:stderr]
    assert_equal "PASSED", result.dig(:json, "baseline", "status")
    assert_equal 0, result.dig(:json, "metrics", "discovered")
    assert_empty result.dig(:json, "analysis", "decisions")
  end

  def test_unsupported_flip_flop_is_excluded_from_supported_analysis
    result = run_fixture("FLIP-01")
    assert_equal 2, result[:status].exitstatus, result[:stderr]
    assert_equal "PASSED", result.dig(:json, "baseline", "status")
    assert_operator result.dig(:json, "metrics", "unsupported"), :>, 0
    assert_equal 0, result.dig(:json, "analysis", "coverage", "decision", "supported_decisions")
  end

  def test_process_exit_is_a_failed_minitest_test
    result = run_fixture("FLOW-12", test_source: <<~RUBY)
      class ProcessTerminationTest < Minitest::Test
        def test_construct_cases
          example("exit")
        end
      end
    RUBY

    assert_equal 1, result[:status].exitstatus, result[:stderr]
    assert_equal "FAILED", result.dig(:json, "baseline", "status")
    assert_equal 1, result.dig(:json, "baseline", "executed_tests")
  end

  private

  def run_fixture(id, level: nil, output: nil, test_source: nil)
    fixture = File.join(FIXTURES, "#{id.downcase.tr("-", "_")}.rb")
    cases = Dir[File.join(FIXTURES, "*.json")].flat_map { |path| JSON.parse(File.read(path)) }
    entry = cases.find { |candidate| candidate.fetch("id") == id }
    raise "missing fixture metadata for #{id}" unless entry

    Dir.mktmpdir("branchproof-construct-cli-") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      FileUtils.cp(fixture, File.join(root, "lib", "construct.rb"))
      source = test_source || <<~RUBY
        class ConstructCorpusTest < Minitest::Test
          CASES = #{JSON.generate(entry.fetch("cases")).inspect}

          def test_construct_cases
            JSON.parse(CASES).each do |sample|
              call = -> { example(*sample.fetch("args", []), **sample.fetch("kwargs", {}).transform_keys(&:to_sym)) }
              if sample.key?("error")
                assert_raises(Object.const_get(sample.fetch("error")), sample.fetch("name"), &call)
              elsif sample.key?("result")
                actual = call.call
                if sample["result"].nil?
                  assert_nil actual, sample.fetch("name")
                else
                  assert_equal sample["result"], actual, sample.fetch("name")
                end
              else
                flunk sample.fetch("name") + " requires a dedicated process-termination test"
              end
            end
          end
        end
      RUBY
      test_file = <<~RUBY
        require "json"
        require "minitest/autorun"
        require_relative "../lib/construct"
        #{source}
      RUBY
      File.write(File.join(root, "test", "construct_test.rb"), test_file)
      File.write(File.join(root, "executions"), "")
      if test_source.nil?
        File.write(File.join(root, "test", "construct_test.rb"), test_file.sub("def test_construct_cases\n", "def test_construct_cases\n              File.open(\"executions\", \"a\") { |file| file.puts \"once\" }\n"))
      end

      args = ["analyze", "lib/construct.rb", "--format", "json", "--test", "test/construct_test.rb"]
      args += ["--level", level.to_s] if level
      args += ["--output", output] if output
      stdout, stderr, status = Open3.capture3({ "MT_NO_PLUGINS" => "1" }, RbConfig.ruby, EXECUTABLE, *args, chdir: root)
      output_json = output && JSON.parse(File.read(File.join(root, output)))
      json = output_json || JSON.parse(stdout)
      execution_lines = File.readlines(File.join(root, "executions"))
      { stdout: stdout, stderr: stderr, status: status, json: json, output_json: output_json,
        execution_lines: execution_lines }
    end
  end
end
