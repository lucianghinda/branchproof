# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "json"

class TestSavedReportAcceptance < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_views_run_once_and_saved_reports_run_offline_with_alias_parity
    with_project do |root|
      %w[conditions tests].each do |view|
        before = marker_count(root)
        stdout, stderr, status = command(root, "analyze", "lib/**/*.rb", "--view", view)
        assert_equal 0, status, stderr
        assert_includes stdout, "lib/decision.rb:2"
        assert_equal before + 1, marker_count(root)
      end
      _, stderr, status = command(root, "analyze", "lib/**/*.rb", "--include", "engines/dummy/lib", "--format", "json",
                                  "--output", "saved.json")
      assert_equal 0, status, stderr
      document = JSON.parse(File.read(File.join(root, "saved.json")))
      assert_equal "1.4", document["schema_version"]
      assert_equal ["lib/**/*.rb"], document.dig("run_metadata", "source_patterns")
      assert_equal ["test/decision_test.rb"], document.dig("run_metadata", "test_files")
      assert_equal %w[lib test engines/dummy/lib], document.dig("run_metadata", "load_paths")
      count = marker_count(root)
      FileUtils.rm_rf(File.join(root, "lib"))
      FileUtils.rm_rf(File.join(root, "test"))
      %w[conditions tests].each do |view|
        primary = command(root, "report", "saved.json", "--view", view)
        legacy = command(root, "report", "saved.json", "--view", view, executable: "mcdc")
        assert_equal 0, primary.last, primary[1]
        assert_equal primary, legacy
        assert_includes primary.first, "lib/decision.rb:2"
        refute_includes primary.first, root
      end
      assert_equal count, marker_count(root)
      primary = command(root, "compare", "saved.json", "saved.json")
      assert_equal 0, primary.last, primary[1]
      assert_equal primary, command(root, "compare", "saved.json", "saved.json", executable: "mcdc")
    end
  end

  def test_report_rejects_input_aliases_and_cleans_failed_output
    with_project do |root|
      command(root, "analyze", "lib/**/*.rb", "--format", "json", "--output", "saved.json")
      path = File.join(root, "saved.json")
      original = File.binread(path)
      File.symlink(path, File.join(root, "symlink.json"))
      File.link(path, File.join(root, "hardlink.json"))
      %w[saved.json symlink.json hardlink.json].each do |output|
        _, stderr, status = command(root, "report", "saved.json", "--output", output)
        assert_equal 2, status
        assert_includes stderr, "overwrite an input"
        _, html_stderr, html_status = command(root, "report", "saved.json", "--format", "html", "--output", output)
        assert_equal 2, html_status
        assert_includes html_stderr, "overwrite an input"
        assert_equal original, File.binread(path)
      end
      FileUtils.mkdir_p(File.join(root, "directory"))
      _, stderr, status = command(root, "report", "saved.json", "--output", "directory")
      assert_equal 2, status
      assert_includes stderr, "branchproof:"
      assert_empty Dir.glob(File.join(root, "directory.tmp-*"))
      assert_equal original, File.binread(path)
    end
  end

  def test_html_report_is_offline_selectable_and_preserves_run_status
    with_project do |root|
      _, stderr, status = command(root, "analyze", "lib/**/*.rb", "--format", "json", "--output", "saved.json")
      assert_equal 0, status, stderr
      marker = marker_count(root)
      FileUtils.rm_rf(File.join(root, "lib"))
      FileUtils.rm_rf(File.join(root, "test"))

      stdout_report = command(root, "report", "saved.json", "--format", "html")
      assert_equal 0, stdout_report.last, stdout_report[1]
      assert_html_document stdout_report.first
      assert_equal marker, marker_count(root)

      output_report = command(root, "report", "saved.json", "--format", "html", "--output", "coverage.html")
      assert_equal 0, output_report.last, output_report[1]
      assert_empty output_report.first
      assert_equal stdout_report.first, File.read(File.join(root, "coverage.html"))
      assert_equal stdout_report, command(root, "report", "saved.json", "--format", "html", executable: "mcdc")

      filtered = command(root, "report", "saved.json", "--format", "html", "--focus", "lib/decision.rb:2",
                         "--top", "1", "--missing-only")
      assert_equal 0, filtered.last, filtered[1]
      assert_html_document filtered.first
      assert_includes filtered.first, "Focus: lib/decision.rb:2"
      assert_equal marker, marker_count(root)

      _, analyze_error, analyze_status = command(root, "analyze", "--format", "html")
      assert_equal 2, analyze_status
      assert_includes analyze_error, "format must be terminal, json, or github"
      _, compare_error, compare_status = command(root, "compare", "saved.json", "saved.json", "--format", "html")
      assert_equal 2, compare_status
      assert_includes compare_error, "format must be terminal or json"
      _, view_error, view_status = command(root, "report", "saved.json", "--format", "html", "--view", "tests")
      assert_equal 2, view_status
      assert_includes view_error, "integrated layout"
      assert_equal marker, marker_count(root)
    end
  end

  def test_failed_and_level_one_reports_preserve_status_and_limits
    with_project do |root|
      command(root, "analyze", "lib/**/*.rb", "--level", "1", "--format", "json", "--output", "saved.json")
      assert_equal 0, command(root, "report", "saved.json").last
      assert_equal 0, command(root, "report", "saved.json", "--level", "3").last
      assert_equal 0, command(root, "report", "saved.json", "--missing-only").last
      legacy = JSON.parse(File.read(File.join(root, "saved.json")))
      legacy["analysis"] = nil
      File.write(File.join(root, "legacy.json"), JSON.generate(legacy))
      assert_equal 0, command(root, "report", "legacy.json", "--level", "1").last
      legacy_html = command(root, "report", "legacy.json", "--format", "html")
      assert_equal 0, legacy_html.last, legacy_html[1]
      assert_html_document legacy_html.first
      assert_includes legacy_html.first, "Analysis: <strong>unavailable</strong>"
      assert_equal 2, command(root, "report", "legacy.json", "--level", "3").last
      File.write(File.join(root, "test/decision_test.rb"), "require 'minitest/autorun'\nclass BrokenTest < Minitest::Test\n def test_failure; flunk; end\nend\n")
      assert_equal 1, command(root, "analyze", "lib/**/*.rb", "--format", "json", "--output", "failed.json").last
      assert_equal 1, command(root, "report", "failed.json").last
      failed_html = command(root, "report", "failed.json", "--format", "html")
      assert_equal 1, failed_html.last
      assert_html_document failed_html.first
    end
  end

  def test_incomplete_html_report_keeps_the_saved_exit_status
    with_project do |root|
      FileUtils.rm_rf(File.join(root, "test"))
      _, stderr, status = command(root, "analyze", "lib/**/*.rb", "--format", "json", "--output", "incomplete.json")
      assert_equal 2, status, stderr

      html = command(root, "report", "incomplete.json", "--format", "html")

      assert_equal 2, html.last, html[1]
      assert_html_document html.first
      assert_includes html.first, "Tests: <strong>INCOMPLETE</strong>"
      assert_includes html.first, "lower bounds"
    end
  end

  def test_primary_and_alias_match_success_failure_and_usage
    with_project do |root|
      %w[branchproof mcdc].each do |executable|
        _, stderr, status = command(root, "analyze", "--bad", executable: executable)
        assert_equal 2, status
        assert_includes stderr, "branchproof:"
      end
      results = %w[branchproof mcdc].map do |executable|
        stdout, stderr, status = command(root, "analyze", "lib/**/*.rb", "--format", "json", executable: executable)
        assert_equal 0, status, stderr
        JSON.parse(stdout).fetch("metrics")
      end
      assert_equal results.first, results.last
      File.write(File.join(root, "test/decision_test.rb"), "require 'minitest/autorun'\nclass FailTest < Minitest::Test\n def test_fail; flunk; end\nend\n")
      %w[branchproof mcdc].each do |executable|
        assert_equal 1, command(root, "analyze", "lib/**/*.rb", executable: executable).last
      end
    end
  end

  def test_saved_policy_status_is_recomputed_instead_of_trusted
    with_project do |root|
      _, stderr, status = command(root, "analyze", "lib/**/*.rb", "--minimum", "mcdc=80", "--format", "json",
                                  "--output", "saved.json")
      assert_equal 0, status, stderr
      document = JSON.parse(File.read(File.join(root, "saved.json")))
      document["coverage_policy"]["status"] = "failed"
      File.write(File.join(root, "forged.json"), JSON.generate(document))

      _, report_stderr, report_status = command(root, "report", "forged.json")
      assert_equal 2, report_status
      assert_includes report_stderr, "coverage_policy"
    end
  end

  private

  def with_project
    Dir.mktmpdir("branchproof-offline-") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      File.write(File.join(root, "lib/decision.rb"), "def decide(left, right)\n  if left && right\n    true\n  else\n    false\n  end\nend\n")
      File.write(File.join(root, "test/decision_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/decision"
        class DecisionTest < Minitest::Test
          def test_evidence
            File.open("marker", "a") { |file| file.puts "run" }
            assert decide(true, true)
            refute decide(true, false)
            refute decide(false, true)
          end
        end
      RUBY
      yield root
    end
  end

  def marker_count(root)
    path = File.join(root, "marker")
    File.exist?(path) ? File.readlines(path).length : 0
  end

  def assert_html_document(html)
    assert_includes html, "<!doctype html>"
    assert_includes html, "Content-Security-Policy"
    assert_includes html, "<style>"
    refute_match(/<script\b/i, html)
    refute_match(/<(?:link|img)\b[^>]*(?:src|href)=["']https?:/i, html)
  end

  def command(root, *, executable: "branchproof")
    stdout, stderr, status = Open3.capture3({ "MT_NO_PLUGINS" => "1" }, RbConfig.ruby,
                                            File.join(ROOT, "exe", executable), *, chdir: root)
    [stdout, stderr, status.exitstatus]
  end
end
