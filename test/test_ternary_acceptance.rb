# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class TernaryAcceptanceTest < Minitest::Test
  GEM_ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.join(GEM_ROOT, "exe", "mcdc")

  def test_compound_predicate_records_predicate_outcomes_and_proves_both_conditions
    result = run_project(source: <<~RUBY, test_source: <<~RUBY, runner_args: ["--seed", "1234"])
      def choose(left, right)
        left && right ? false : true
      end
    RUBY
      class CompoundTernaryTest < Minitest::Test
        def test_false_false
          assert_equal true, choose(false, false)
        end

        def test_false_true
          assert_equal true, choose(false, true)
        end

        def test_true_false
          assert_equal true, choose(true, false)
        end

        def test_true_true
          assert_equal false, choose(true, true)
        end
      end
    RUBY

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    report = result.fetch(:json)
    decision = ternary_decisions(report).fetch(0)
    assert_equal "ternary", decision.fetch("context")
    assert_equal 2, decision.fetch("conditions").length
    assert_equal "and", decision.fetch("tree").fetch("type")
    refute decision.fetch("support_reasons").include?("unsupported_ternary")

    vectors = vectors_for(report, decision)
    assert_equal 3, vectors.length
    observed_outcomes = vectors.to_h { |vector| [vector.fetch("values"), vector.fetch("outcome")] }
    assert_equal false, observed_outcomes.fetch([false, nil])
    assert_equal false, observed_outcomes.fetch([true, false])
    assert_equal true, observed_outcomes.fetch([true, true])
    assert_equal %w[PROVEN PROVEN], decision_result_statuses(report, decision)

    owners = owner_method_names(report, vectors)
    %w[test_false_false test_false_true test_true_false test_true_true].each do |test_name|
      assert_includes owners, test_name
    end
  end

  def test_unchosen_nested_branch_does_not_execute_or_observe_inner_ternary
    result = run_project(source: <<~RUBY, test_source: <<~RUBY)
      def nested_branch(value)
        value ? (false ? (File.write(ENV.fetch("BRANCHPROOF_MARKER"), "bad") && :bad) : :safe) : :outside
      end
    RUBY
      class NestedBranchTernaryTest < Minitest::Test
        def test_false_skips_inner_branch
          assert_equal :outside, nested_branch(false)
          refute File.exist?(ENV.fetch("BRANCHPROOF_MARKER"))
        end

        def test_true_uses_safe_inner_branch
          assert_equal :safe, nested_branch(true)
          refute File.exist?(ENV.fetch("BRANCHPROOF_MARKER"))
        end
      end
    RUBY

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    report = result.fetch(:json)
    decisions = ternary_decisions(report)
    assert_equal 2, decisions.length
    outer, inner = decisions.sort_by { |decision| decision.fetch("line") }
    assert_equal 2, vectors_for(report, outer).length
    assert_equal 1, vectors_for(report, inner).length
    assert_equal 0, report.fetch("metrics").fetch("aborted")
    assert_equal 1, report.fetch("metrics").fetch("unexecuted")
    short_circuit = report.fetch("source_inventory").fetch("decisions").find do |decision|
      decision.fetch("context") == "short_circuit" && decision.fetch("expression").include?("File.write")
    end
    refute_nil short_circuit
    assert_empty vectors_for(report, short_circuit)
  end

  def test_ternary_inside_if_predicate_has_independent_inventory_and_exact_execution
    result = run_project(source: <<~RUBY, test_source: <<~RUBY, runner_args: ["--seed", "1234"])
      def outer_decision(left, right)
        if left ? right : false
          :yes
        else
          :no
        end
      end
    RUBY
      class OuterIfTernaryTest < Minitest::Test
        def test_false_false
          assert_equal :no, outer_decision(false, false)
        end

        def test_false_true
          assert_equal :no, outer_decision(false, true)
        end

        def test_true_false
          assert_equal :no, outer_decision(true, false)
        end

        def test_true_true
          assert_equal :yes, outer_decision(true, true)
        end
      end
    RUBY

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    decisions = result.fetch(:json).fetch("source_inventory").fetch("decisions")
    assert_equal 2, decisions.length
    ternary = decisions.find { |decision| decision.fetch("context") == "ternary" }
    outer_if = decisions.find { |decision| decision.fetch("context") == "if" }
    assert_equal "ternary", ternary.fetch("context")
    refute_equal "ternary", outer_if.fetch("context")
    assert_equal(4, vectors_for(result.fetch(:json), ternary).sum { |vector| vector.fetch("count") })
    assert_equal(4, vectors_for(result.fetch(:json), outer_if).sum { |vector| vector.fetch("count") })
    assert_equal 2, result.fetch(:json).fetch("metrics").fetch("discovered")
  end

  def test_three_nested_ternaries_record_each_executed_decision_once
    result = run_project(source: <<~RUBY, test_source: <<~RUBY)
      def deeply_nested(a, b, c)
        ((a ? b : c) ? :middle_yes : :middle_no) ? :outer_yes : :outer_no
      end
    RUBY
      class DeepNestingTernaryTest < Minitest::Test
        def test_all_true
          assert_equal :outer_yes, deeply_nested(true, true, true)
        end
      end
    RUBY

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    decisions = ternary_decisions(result.fetch(:json))
    assert_equal 3, decisions.length
    decisions.each do |decision|
      assert_equal 1, vectors_for(result.fetch(:json), decision).length, decision.fetch("id")
      assert_equal ["test_all_true"], owner_method_names(result.fetch(:json), vectors_for(result.fetch(:json), decision)).uniq
    end
    assert_equal 3, result.fetch(:json).fetch("metrics").fetch("completed")
    assert_equal 0, result.fetch(:json).fetch("metrics").fetch("aborted")
  end

  def test_raised_predicate_is_aborted_and_following_clean_frame_completes
    result = run_project(source: <<~RUBY, test_source: <<~RUBY)
      def recover_from_predicate
        begin
          (raise "predicate exploded") ? :never : :never
        rescue RuntimeError
          true ? :clean : :dirty
        end
      end
    RUBY
      class PredicateAbortTernaryTest < Minitest::Test
        def test_recovery
          assert_equal :clean, recover_from_predicate
        end
      end
    RUBY

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    report = result.fetch(:json)
    ternaries = ternary_decisions(report)
    assert_equal 2, ternaries.length
    assert_operator report.fetch("metrics").fetch("aborted"), :>=, 1
    assert_equal 2, report.fetch("metrics").fetch("completed")
    boolean_rows = ternaries.map do |decision|
      report.fetch("analysis").fetch("decisions").find { |row| row.fetch("decision_id") == decision.fetch("id") }
    end
    assert(boolean_rows.all? { |row| row.fetch("condition_results").any? })
    exception = report.fetch("source_inventory").fetch("decisions").find do |decision|
      decision.fetch("context") == "rescue"
    end
    refute_nil exception
    exception_row = report.fetch("analysis").fetch("decisions").find do |row|
      row.fetch("decision_id") == exception.fetch("id")
    end
    assert_equal "partial", exception_row.dig("coverage", "alternative", "status")
    refute_empty report.fetch("observations").fetch("vectors")
    assert_equal true, report.fetch("completeness").fetch("observation")
    assert_equal true, report.fetch("completeness").fetch("attribution")
  end

  def test_unsafe_ternary_predicate_keeps_diagnostic_without_rejecting_ordinary_ternary
    result = run_project(source: <<~RUBY, test_source: <<~RUBY)
      def safe(value)
        value ? :yes : :no
      end

      def unsafe
        (<<~TEXT) ? :yes : :no
        value
        TEXT
      end
    RUBY
      class TernaryDiagnosticTest < Minitest::Test
        def test_safe_ternary
          assert_equal :yes, safe(true)
        end
      end
    RUBY

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    report = result.fetch(:json)
    safe, unsafe = ternary_decisions(report).sort_by { |decision| decision.fetch("line") }
    assert_empty safe.fetch("support_reasons")
    assert_includes unsafe.fetch("support_reasons"), "unsupported_heredoc"
    refute_includes safe.fetch("support_reasons"), "unsupported_ternary"
  end

  def test_terminal_report_contains_ternary_decision_and_evidence
    result = run_project(source: "def choose(value)\n  value ? :yes : :no\nend\n",
                         test_source: <<~RUBY, format: "terminal")
                           class TerminalTernaryTest < Minitest::Test
                             def test_false
                               assert_equal :no, choose(false)
                             end

                             def test_true
                               assert_equal :yes, choose(true)
                             end
                           end
                         RUBY

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    assert_includes result.fetch(:stdout), "Decision"
    assert_includes result.fetch(:stdout), "value"
    assert_includes result.fetch(:stdout), "PROVEN"
  end

  private

  def ternary_decisions(report)
    report.fetch("source_inventory").fetch("decisions").select { |decision| decision["context"] == "ternary" }
  end

  def vectors_for(report, decision)
    report.fetch("observations").fetch("vectors").select { |vector| vector.fetch("decision_id") == decision.fetch("id") }
  end

  def decision_result_statuses(report, decision)
    report.fetch("analysis").fetch("decisions").find { |item| item.fetch("decision_id") == decision.fetch("id") }
          .fetch("condition_results").map { |result| result.fetch("status") }
  end

  def owner_method_names(report, vectors)
    owners = vectors.flat_map { |vector| vector.fetch("test_ids") }.uniq
    report.fetch("observations").fetch("tests").select { |test| owners.include?(test.fetch("id")) }
          .map { |test| test.fetch("method_name") }
  end

  def run_project(source:, test_source:, format: "json", runner_args: [])
    Dir.mktmpdir("branchproof-ternary-acceptance-") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      source_path = File.join(root, "lib", "decision.rb")
      test_path = File.join(root, "test", "decision_test.rb")
      File.binwrite(source_path, source)
      File.binwrite(test_path, "require #{source_path.inspect}\nrequire \"minitest/autorun\"\n#{test_source}")
      marker_path = File.join(root, "branch-marker")
      env = { "MT_NO_PLUGINS" => "1",
              "BRANCHPROOF_MARKER" => marker_path }
      cli_args = ["analyze", source_path, "--format", format, "--test", test_path, "--", *runner_args]
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, EXECUTABLE, *cli_args, chdir: root)
      parsed = format == "json" ? JSON.parse(stdout) : nil
      { root: root, stdout: stdout, stderr: stderr, status: status, json: parsed }
    end
  end
end
