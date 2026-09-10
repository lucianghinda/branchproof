# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "json"

class TestComparisonAcceptance < Minitest::Test
  EXECUTABLE = File.expand_path("../exe/branchproof", __dir__)

  def test_saved_runs_explain_lost_gained_and_changed_source_without_running_tests
    Dir.mktmpdir("branchproof-comparison-") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      source = File.join(root, "lib/decision.rb")
      File.write(source, "def decide(left, right)\n  if left && right\n    true\n  else\n    false\n  end\nend\n")
      write_tests(root, full: true)
      save(root, "before.json")
      write_tests(root, full: false)
      save(root, "after.json")
      marker = File.read(File.join(root, "marker"))
      stdout, stderr, status = command(root, "compare", "before.json", "after.json")
      assert_equal 0, status, stderr
      assert_match(/lost proof/i, stdout)
      assert_includes stdout, "lib/decision.rb:2"
      assert_includes stdout, "DecisionTest#test_false"
      assert_includes stdout, "not observed in current run"
      assert_equal 1, command(root, "compare", "before.json", "after.json", "--fail-on-regression").last
      stdout, stderr, status = command(root, "compare", "after.json", "before.json", "--fail-on-regression")
      assert_equal 0, status, stderr
      assert_match(/gained proof/i, stdout)
      assert_equal marker, File.read(File.join(root, "marker"))
      stdout, stderr, status = command(root, "compare", "before.json", "after.json", "--format", "json")
      assert_equal 0, status, stderr
      assert_equal "1.0", JSON.parse(stdout).fetch("schema_version")
      File.write(source, "# changed comment\n#{File.read(source)}")
      save(root, "changed.json")
      stdout, stderr, status = command(root, "compare", "before.json", "changed.json", "--fail-on-regression")
      assert_equal 2, status, stderr
      assert_match(/source changed/i, stdout)
      refute_match(/lost proof:/i, stdout)
      before = File.binread(File.join(root, "before.json"))
      assert_equal 2, command(root, "compare", "before.json", "after.json", "--output", "before.json").last
      assert_equal before, File.binread(File.join(root, "before.json"))
    end
  end

  private

  def write_tests(root, full:)
    false_test = full ? "def test_false; refute decide(true, false); end" : ""
    File.write(File.join(root, "test/decision_test.rb"), <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/decision"
      class DecisionTest < Minitest::Test
        def test_true
          File.open("marker", "a") { |file| file.puts "run" }
          assert decide(true, true)
        end
        def test_left; refute decide(false, true); end
        #{false_test}
      end
    RUBY
  end

  def save(root, path)
    _, stderr, status = command(root, "analyze", "lib/**/*.rb", "--format", "json", "--output", path)
    assert_equal 0, status, stderr
  end

  def command(root, *)
    stdout, stderr, status = Open3.capture3({ "MT_NO_PLUGINS" => "1" }, RbConfig.ruby, EXECUTABLE, *, chdir: root)
    [stdout, stderr, status.exitstatus]
  end
end
