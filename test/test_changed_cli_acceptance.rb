# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class TestChangedCLIAcceptance < Minitest::Test
  GEM_ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.join(GEM_ROOT, "exe", "branchproof")

  def test_normal_json_stays_at_1_4_and_changed_json_keeps_full_run_records
    with_project do |root, base|
      normal = analyze(root)
      scoped = analyze(root, "--changed-since", base)

      assert_equal 0, normal[:status].exitstatus, normal[:stderr]
      assert_equal "1.4", normal.fetch(:json).fetch("schema_version")
      refute normal.fetch(:json).key?("changed_scope")
      assert_equal 0, scoped[:status].exitstatus, scoped[:stderr]
      assert_equal "1.5", scoped.fetch(:json).fetch("schema_version")
      assert_equal "complete", scoped.dig(:json, "changed_scope", "status")
      assert_equal "PASSED", scoped.dig(:json, "baseline", "status")
      assert_equal 1, scoped.dig(:json, "baseline", "executed_tests")
      assert_equal 2, scoped.dig(:json, "source_inventory", "decisions").length
      assert_equal 2, scoped.dig(:json, "analysis", "decisions").length
      assert_equal 1, scoped.dig(:json, "changed_coverage", "selected_decisions")
    end
  end

  def test_changed_since_captures_staged_and_unstaged_edits_but_excludes_untracked_files
    with_project do |root, base|
      path = File.join(root, "lib", "decision.rb")
      git(root, "add", "lib/decision.rb")
      File.write(path, File.read(path).sub("value == :other", "value == :different"))
      File.write(File.join(root, "lib", "untracked.rb"), "if ignored?\nend\n")

      result = analyze(root, "--changed-since", base)

      assert_equal 0, result[:status].exitstatus, result[:stderr]
      files = result.dig(:json, "changed_scope", "files")
      paths = files.map { |file| file.fetch("path") }
      assert_equal ["lib/decision.rb"], paths
      assert_equal "complete", result.dig(:json, "changed_scope", "status")
      assert_equal 2, result.dig(:json, "changed_scope", "decision_ids").length
    end
  end

  def test_comment_only_change_has_unavailable_changed_coverage
    with_project(changed: false) do |root, base|
      path = File.join(root, "lib", "decision.rb")
      File.write(path, File.read(path).sub("if value && value != :never", "if value && value != :never # clarified"))

      result = analyze(root, "--changed-since", base, "--minimum", "decision=0")

      assert_equal 0, result[:status].exitstatus, result[:stderr]
      assert_equal "empty", result.dig(:json, "changed_scope", "status")
      assert_empty result.dig(:json, "changed_scope", "decision_ids")
      assert_equal "unavailable", result.dig(:json, "changed_coverage", "status")
      assert_nil result.dig(:json, "changed_coverage", "coverage", "decision", "percentage")
    end
  end

  def test_bad_changed_since_values_fail_before_test_body_runs
    with_project do |root, _base|
      marker = File.join(root, "test-ran")
      [["--changed-since"], ["--changed-since", "--help"], ["--changed-since", "missing-ref"],
       ["--changed-since", "--bad-ref"]].each do |args|
        result = analyze(root, *args, marker: marker)
        assert_equal 2, result[:status].exitstatus, "#{args.inspect}: #{result[:stderr]}"
        assert_match(/changed-since|commit|reference|ref/i, result[:stderr])
        refute File.exist?(marker), "test body ran for #{args.inspect}"
      end
    end
  end

  def test_changed_since_is_rejected_by_offline_commands_before_opening_snapshots
    report = cli("report", "missing-report.json", "--changed-since", "HEAD")
    compare = cli("compare", "missing-before.json", "missing-after.json", "--changed-since", "HEAD")

    [report, compare].each do |result|
      assert_equal 2, result[:status].exitstatus
      assert_match(/changed-since.*analyze/i, result[:stderr])
      refute_match(/missing-(?:report|before|after)/, result[:stderr])
    end
  end

  def test_changed_since_requires_a_git_repository_before_running_tests
    Dir.mktmpdir("branchproof-not-git-") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      File.write(File.join(root, "lib", "decision.rb"), "if ready?\nend\n")
      File.write(File.join(root, "test", "decision_test.rb"), <<~RUBY)
        require "minitest/autorun"
        class MarkerTest < Minitest::Test
          def test_marker
            File.write(ENV.fetch("BRANCHPROOF_TEST_MARKER"), "ran")
          end
        end
      RUBY
      marker = File.join(root, "test-ran")

      result = analyze(root, "--changed-since", "HEAD", marker: marker)

      assert_equal 2, result[:status].exitstatus
      assert_match(/git repository/i, result[:stderr])
      refute File.exist?(marker)
    end
  end

  def test_saved_changed_scope_renders_after_checkout_is_removed
    Dir.mktmpdir("branchproof-offline-report-") do |offline_root|
      snapshot = File.join(offline_root, "snapshot.json")
      saved_scope = nil
      with_project do |root, base|
        result = analyze(root, "--changed-since", base, "--output", snapshot)
        assert_equal 0, result[:status].exitstatus, result[:stderr]
        refute result.fetch(:json)
        saved_scope = JSON.parse(File.read(snapshot)).fetch("changed_scope")
      end

      rendered = cli("report", snapshot, "--format", "json", chdir: offline_root)

      assert_equal 0, rendered[:status].exitstatus, rendered[:stderr]
      assert_equal saved_scope, rendered.dig(:json, "changed_scope")
      assert_equal "1.5", rendered.dig(:json, "schema_version")
    end
  end

  def test_whole_run_minimum_can_fail_when_changed_decisions_pass
    with_project(test_source: <<~RUBY) do |root, base|
      class ChangedScopeMinimumTest < Minitest::Test
        def test_changed_decision
          assert_equal :yes, branchproof_value(true)
          assert_equal :no, branchproof_value(false)
        end
      end
    RUBY
      result = analyze(root, "--changed-since", base, "--minimum", "decision=100")

      assert_equal 1, result[:status].exitstatus, result[:stderr]
      assert_equal 100.0, result.dig(:json, "changed_coverage", "coverage", "decision", "percentage")
      assert_equal 50.0, result.dig(:json, "analysis", "coverage", "decision", "percentage")
    end
  end

  def test_json_allows_scope_but_preserves_focus_and_top_rejections
    with_project do |root, base|
      scoped = analyze(root, "--changed-since", base)
      focused = analyze(root, "--changed-since", base, "--focus", "lib/decision.rb")
      topped = analyze(root, "--changed-since", base, "--top", "1")

      assert_equal 0, scoped[:status].exitstatus, scoped[:stderr]
      [focused, topped].each do |result|
        assert_equal 2, result[:status].exitstatus
        assert_match(/terminal-only/, result[:stderr])
      end
    end
  end

  def test_scope_never_skips_a_selected_failing_test
    with_project(test_source: <<~RUBY) do |root, base|
      class ChangedScopeFailureTest < Minitest::Test
        def test_failure
          assert_equal 1, 2
        end
      end
    RUBY
      result = analyze(root, "--changed-since", base)

      assert_equal 1, result[:status].exitstatus, result[:stderr]
      assert_equal "FAILED", result.dig(:json, "baseline", "status")
      assert_equal 1, result.dig(:json, "baseline", "failed_tests")
      assert_equal 1, result.dig(:json, "baseline", "executed_tests")
    end
  end

  private

  def with_project(test_source: nil, changed: true)
    Dir.mktmpdir("branchproof-changed-cli-") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      File.write(File.join(root, "lib", "decision.rb"), <<~RUBY)
        def branchproof_value(value)
          result = if value && value != :never
            :yes
          else
            :no
          end
          if value == :other
            :other
          else
            result
          end
        end
      RUBY
      File.write(File.join(root, "test", "decision_test.rb"), <<~RUBY)
        require #{File.join(root, "lib", "decision.rb").inspect}
        require "minitest/autorun"
        #{test_source || passing_test_source}
      RUBY
      git(root, "init", "-q")
      git(root, "config", "user.name", "Branchproof Test")
      git(root, "config", "user.email", "branchproof@example.test")
      git(root, "add", "lib/decision.rb", "test/decision_test.rb")
      git(root, "commit", "-qm", "baseline")
      base = git(root, "rev-parse", "HEAD").strip
      if changed
        source = File.join(root, "lib", "decision.rb")
        File.write(source, File.read(source).sub("value != :never", "value != :never && value != :special"))
      end
      yield root, base
    end
  end

  def passing_test_source
    <<~RUBY
      class PassingTest < Minitest::Test
        def test_passes
          File.write(ENV.fetch("BRANCHPROOF_TEST_MARKER"), "ran") if ENV["BRANCHPROOF_TEST_MARKER"]
          assert_equal :yes, branchproof_value(true)
        end
      end
    RUBY
  end

  def analyze(root, *, marker: nil)
    cli("analyze", "lib/decision.rb", "--test", "test/decision_test.rb", "--format", "json", *,
        chdir: root, env: marker ? { "BRANCHPROOF_TEST_MARKER" => marker } : {})
  end

  def cli(*, chdir: nil, env: {})
    root = chdir || Dir.pwd
    stdout, stderr, status = Open3.capture3({ "MT_NO_PLUGINS" => "1" }.merge(env), RbConfig.ruby,
                                            EXECUTABLE, *, chdir: root)
    json = JSON.parse(stdout) if stdout.start_with?("{")
    { stdout: stdout, stderr: stderr, status: status, json: json }
  rescue JSON::ParserError
    { stdout: stdout, stderr: stderr, status: status, json: nil }
  end

  def git(root, *args)
    output, status = Open3.capture2e("git", *args, chdir: root)
    raise "git #{args.join(" ")} failed: #{output}" unless status.success?

    output
  end
end
