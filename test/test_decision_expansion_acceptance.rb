# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "rbconfig"

class TestDecisionExpansionAcceptance < Minitest::Test
  def test_one_minitest_run_attributes_all_categories_and_reopens_offline
    Dir.mktmpdir("branchproof-expansion") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      File.write(File.join(root, "lib/expanded.rb"), <<~APP)
        def expanded(value)
          count = 0
          count += 1 while count < 2
          name = value&.to_s
          name ||= "missing"
          selected = case value
                     when :ok, :other then :known
                     else :unknown
                     end
          matched = (value in Symbol)
          allowed = !matched || count == 2
          [selected, name, allowed]
        end
      APP
      File.write(File.join(root, "test/expanded_test.rb"), <<~TEST)
        require "minitest/autorun"
        require_relative "../lib/expanded"
        class ExpansionTest < Minitest::Test
          def test_values
            File.open("executions", "a") { |file| file.puts "once" }
            assert_equal [:known, "ok", true], expanded(:ok)
            assert_equal [:known, "other", true], expanded(:other)
            assert_equal [:unknown, "missing", true], expanded(nil)
          end
        end
      TEST
      stdout, stderr, status = command(root, "analyze", "lib/**/*.rb", "--format", "json", "--output", "report.json")
      assert_equal 0, status, "#{stderr}\n#{stdout}"
      document = Branchproof::SavedReport.read(File.join(root, "report.json"))
      assert_equal "1.3", document["schema_version"]
      inventory = document.fetch("source_inventory").fetch("decisions")
      assert_equal %w[case or_assignment pattern_in safe_navigation short_circuit while],
                   inventory.map { |decision| decision.fetch("context") }.sort
      assert_equal %w[boolean implicit multiway], inventory.map { |decision| decision.fetch("kind") }.uniq.sort
      assert(document.fetch("observations").fetch("vectors").all? { |vector| vector["test_ids"].length == 1 })
      assert_equal 3, document.dig("analysis", "coverage", "decision", "supported_decisions")
      assert_equal 7, document.dig("analysis", "coverage", "alternative", "required_alternatives")
      FileUtils.rm_rf(File.join(root, "lib"))
      FileUtils.rm_rf(File.join(root, "test"))
      %w[decisions conditions tests].each do |view|
        output, error, result = command(root, "report", "report.json", "--view", view)
        assert_equal 0, result, error
        assert_includes output, "Coverage ladder"
      end
      assert_equal ["once\n"], File.readlines(File.join(root, "executions"))
    end
  end

  def test_flow_only_project_has_a_valid_scope_and_actionable_missing_report
    Dir.mktmpdir("branchproof-flow-only") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      File.write(File.join(root, "lib/paths.rb"), "def path(value) = value&.to_s\n")
      File.write(File.join(root, "test/paths_test.rb"), <<~TEST)
        require "minitest/autorun"
        require_relative "../lib/paths"
        class PathsTest < Minitest::Test
          def test_nil
            assert_nil path(nil)
          end
        end
      TEST
      output, error, status = command(root, "analyze", "lib/**/*.rb", "--missing-only")
      assert_equal 0, status, "#{error}\n#{output}"
      assert_includes output, "receiver non-nil"
      assert_includes output, "MC/DC: N/A"
      refute_includes output, "No eligible conditions"
      refute_includes output, "No missing conditions"
    end
  end

  private

  def command(root, *)
    executable = File.expand_path("../exe/branchproof", __dir__)
    stdout, stderr, status = Open3.capture3({ "MT_NO_PLUGINS" => "1" }, RbConfig.ruby, executable, *, chdir: root)
    [stdout, stderr, status.exitstatus]
  end
end
