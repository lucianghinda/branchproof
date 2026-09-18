# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "support/rspec_constructs"

class TestRSpecConstructs < Minitest::Test
  def test_rspec_executes_the_complete_native_construct_corpus
    Dir.mktmpdir("branchproof-rspec-corpus-") do |root|
      RSpecConstructs.write_project(root)
      stdout, stderr, status = Open3.capture3({ "MT_NO_PLUGINS" => "1" }, RbConfig.ruby,
                                              RSpecConstructs::EXECUTABLE, "analyze", "lib/corpus/**/*.rb",
                                              "--framework", "rspec", "--format", "json",
                                              "--test", "spec/corpus_spec.rb", chdir: root)
      report = JSON.parse(stdout)
      assert status.success?, stderr
      assert_equal "PASSED", report.dig("baseline", "status"), stderr
      assert_equal RSpecConstructs.non_terminating_cases, report.dig("baseline", "executed_tests")
      assert_equal 0, report.dig("baseline", "failed_tests")
      framework = report.dig("run_metadata", "framework") || report.dig("baseline", "project", "framework")
      assert_equal "rspec", framework
      assert_equal RSpecConstructs.decision_count, report.dig("metrics", "discovered")
      assert_equal 143, RSpecConstructs.decision_bearing_count
      assert_empty RubyConstructs.inventory("PRED-15").fetch(:decisions)
      assert_native_vectors_match(report)
    end
  end

  def test_process_termination_cases_are_checked_against_native_exit_statuses
    checked = 0
    RubyConstructs.entries.each do |entry|
      entry.fetch("cases").select { |sample| sample.key?("exit") }.each do |sample|
        actual = RubyConstructs.capture(entry.fetch("id"), sample)
        assert_equal sample.fetch("exit"), actual.fetch(:exitstatus), entry.fetch("id")
        assert_rspec_termination(entry.fetch("id"), sample)
        checked += 1
      end
    end
    assert_equal 3, checked
  end

  private

  def assert_native_vectors_match(report)
    source_paths = report.fetch("source_inventory").fetch("source_units").to_h do |unit|
      [unit.fetch("source_id"), unit.fetch("relative_path")]
    end
    decisions = report.fetch("source_inventory").fetch("decisions")
    vectors = report.fetch("observations").fetch("vectors")
    RSpecConstructs.entries.each do |entry|
      id = entry.fetch("id")
      next if entry.fetch("cases").all? { |sample| sample.key?("exit") }

      actual_decisions = decisions.select { |decision| source_paths.fetch(decision.fetch("source_id")).end_with?("/#{id.downcase.tr("-", "_")}.rb") }
      expected = RubyConstructs.document(id)
      expected_decisions = expected.fetch(:inventory).fetch(:decisions)
      expected_decisions.each do |expected_decision|
        actual = actual_decisions.find do |candidate|
          candidate.values_at("context", "byte_start", "byte_length") ==
            expected_decision.values_at(:context, :byte_start, :byte_length)
        end
        refute_nil actual, "#{id}: missing decision #{expected_decision.fetch(:context)}"

        actual_pairs = vectors.select { |vector| vector.fetch("decision_id") == actual.fetch("id") }
                              .map { |vector| [vector.fetch("values"), vector.fetch("outcome")] }.uniq.sort_by(&:inspect)
        expected_pairs = expected.fetch(:evidence).fetch(:vectors)
                                 .select { |vector| vector.fetch(:decision_id) == expected_decision.fetch(:id) }
                                 .map { |vector| [vector.fetch(:values), vector.fetch(:outcome)] }.uniq.sort_by(&:inspect)
        assert_equal expected_pairs, actual_pairs, "#{id}: #{expected_decision.fetch(:context)}"
        assert_analysis_proof_matches(report, actual, expected, expected_decision, id)
      end
    end
  end

  def assert_analysis_proof_matches(report, actual_decision, expected, expected_decision, fixture_id)
    actual_row = report.fetch("analysis").fetch("decisions").find do |row|
      row.fetch("decision_id") == actual_decision.fetch("id")
    end
    refute_nil actual_row, "#{fixture_id}: missing analysis row"
    expected_row = expected.fetch(:analysis).fetch(:decisions).find do |row|
      row.fetch(:decision_id) == expected_decision.fetch(:id)
    end
    refute_nil expected_row, "#{fixture_id}: missing native analysis row"
    if expected_decision.fetch(:kind) == "boolean"
      %w[decision condition condition_decision mcdc].each do |criterion|
        assert_equal expected_row.fetch(:coverage).fetch(criterion.to_sym).fetch(:status),
                     actual_row.fetch("coverage").fetch(criterion).fetch("status"), fixture_id
      end
      assert_equal expected_row.fetch(:coverage).fetch(:decision).fetch(:covered_outcomes),
                   actual_row.fetch("coverage").fetch("decision").fetch("covered_outcomes"), fixture_id
    else
      expected_coverage = expected_row.fetch(:coverage).fetch(:alternative)
      actual_coverage = actual_row.fetch("coverage").fetch("alternative")
      %w[status covered_alternatives required_alternatives].each do |field|
        assert_equal expected_coverage.fetch(field.to_sym), actual_coverage.fetch(field), fixture_id
      end
      expected_alternatives = expected_coverage.fetch(:alternatives).map do |alternative|
        [alternative.fetch(:index), alternative.fetch(:expression), alternative.fetch(:selected).fetch(:observed),
         alternative.fetch(:not_selected).fetch(:observed)]
      end
      actual_alternatives = actual_coverage.fetch("alternatives").map do |alternative|
        [alternative.fetch("index"), alternative.fetch("expression"), alternative.fetch("selected").fetch("observed"),
         alternative.fetch("not_selected").fetch("observed")]
      end
      assert_equal expected_alternatives, actual_alternatives, fixture_id
    end
  end

  def assert_rspec_termination(id, sample)
    Dir.mktmpdir("branchproof-rspec-exit-") do |root|
      RSpecConstructs.write_project(root, ids: [id])
      path = File.join(root, "lib", "corpus", "#{id.downcase.tr("-", "_")}.rb")
      args = sample.fetch("args").inspect
      File.write(File.join(root, "spec", "corpus_spec.rb"), <<~RUBY)
        RSpec.describe "#{id}" do
          it("#{sample.fetch("name")}") do
            scope = Module.new
            load(#{path.inspect}, scope)
            Object.new.extend(scope).send(:example, *#{args})
          end
        end
      RUBY
      stdout, stderr, status = Open3.capture3({ "MT_NO_PLUGINS" => "1" }, RbConfig.ruby,
                                              RSpecConstructs::EXECUTABLE, "analyze", "lib/corpus/**/*.rb",
                                              "--framework", "rspec", "--format", "json",
                                              "--test", "spec/corpus_spec.rb", chdir: root)
      refute status.success?, "#{id}/#{sample.fetch("name")} unexpectedly succeeded: #{stdout} #{stderr}"
      assert_equal 2, status.exitstatus, "#{id}/#{sample.fetch("name")}: #{stderr}"
      if stdout.empty?
        assert_match(/(?:exit|worker|incomplete|error)/i, stderr)
      else
        report = JSON.parse(stdout)
        assert_includes %w[ERROR INCOMPLETE], report.dig("baseline", "status")
        refute_equal true, report.dig("baseline", "finalized")
      end
    end
  end
end
