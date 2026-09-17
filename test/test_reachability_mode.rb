# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class TestReachabilityMode < Minitest::Test
  EXECUTABLE = File.expand_path("../exe/branchproof", __dir__)

  def with_project
    Dir.mktmpdir("branchproof-reachability-") do |root|
      source = File.join(root, "policy.rb")
      tests = File.join(root, "policy_test.rb")
      File.write(source, "def policy(value)\n  value && false\nend\n")
      File.write(tests, <<~RUBY)
        require #{source.inspect}
        require "minitest/autorun"
        class PolicyTest < Minitest::Test
          def test_policy
            refute policy(false)
            refute policy(true)
          end
        end
      RUBY
      yield root, source, tests
    end
  end

  def test_disabling_reachability_keeps_every_generated_rule_as_an_obligation
    with_project do |root, source, tests|
      stdout, stderr, status = Open3.capture3(
        { "MT_NO_PLUGINS" => "1" }, RbConfig.ruby, EXECUTABLE,
        "analyze", source, "--test", tests, "--format", "json", "--no-reachability", chdir: root
      )
      assert_equal 0, status.exitstatus, stderr
      document = JSON.parse(stdout)
      table = document.fetch("analysis").fetch("decisions").first.fetch("decision_table")
      refute table.fetch("reachability_analyzed")
      assert_equal 3, table.fetch("required_rules")
      assert_equal 2, table.fetch("covered_rules")
      assert_equal 0, table.fetch("impossible_rules")
      assert_equal "unknown", table.fetch("rules").last.fetch("reachability")
      refute document.fetch("run_metadata").fetch("reachability")

      saved = File.join(root, "report.json")
      File.write(saved, stdout)
      rendered, errors, reopened = Open3.capture3(RbConfig.ruby, EXECUTABLE, "report", saved)
      assert_equal 0, reopened.exitstatus, errors
      assert_includes rendered, "Reachability: not analyzed"
    end
  end

  def test_underscore_view_alias_remains_supported
    with_project do |root, source, tests|
      stdout, stderr, status = Open3.capture3(
        { "MT_NO_PLUGINS" => "1" }, RbConfig.ruby, EXECUTABLE,
        "analyze", source, "--test", tests, "--view", "decision_tables", chdir: root
      )
      assert_equal 0, status.exitstatus, stderr
      assert_includes stdout, "Branchproof focused view: decision_tables"
    end
  end
end
