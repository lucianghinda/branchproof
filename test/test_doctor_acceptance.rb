# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class TestDoctorAcceptance < Minitest::Test
  ROOT = File.expand_path("..", __dir__).freeze
  EXECUTABLE = File.join(ROOT, "exe", "branchproof").freeze

  def test_real_cli_reports_ruby_minitest_rspec_and_rails_layouts_without_running_project_code
    Dir.mktmpdir("branchproof-doctor-") do |directory|
      marker = File.join(directory, "executed")
      project = File.join(directory, "project")
      create_project(project, marker: marker, rails: true)
      write(project, ".rspec", "--require spec_helper\n")
      write(project, "spec/decision_spec.rb", "File.write(#{marker.inspect}, 'spec')\n")
      write(project, "test/decision_test.rb", "File.write(#{marker.inspect}, 'test')\n")

      snapshot = tree_snapshot(project)
      cases = [
        [%w[--project ruby --framework minitest], "minitest", "ruby"],
        [%w[--project ruby --framework rspec], "rspec", "ruby"],
        [%w[--project rails --framework minitest], "minitest", "rails"],
        [%w[--project auto --framework minitest], "minitest", "rails"]
      ]

      cases.each do |options, framework, project_kind|
        result = run_doctor(project, *options, "--format", "json")

        assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
        document = JSON.parse(result.fetch(:stdout))
        assert_equal "ready", document.fetch("status")
        assert_equal ["application boot", "dependency loading", "test execution"], document.fetch("not_checked")
        assert_equal framework, document.dig("framework", "name")
        assert_equal project_kind, document.dig("project", "kind")
      end

      terminal = run_doctor(project, "--project", "ruby", "--framework", "minitest")
      assert_equal 0, terminal.fetch(:status).exitstatus, terminal.fetch(:stderr)
      assert_includes terminal.fetch(:stdout), "Project: ruby ("
      assert_includes terminal.fetch(:stdout), "Framework: minitest "
      assert_includes terminal.fetch(:stdout), "Sources: 2 files"
      assert_includes terminal.fetch(:stdout), "Tests: 1 files"
      assert_includes terminal.fetch(:stdout), "Static-only: Static checks only:"
      assert_includes terminal.fetch(:stdout),
                      "Not checked: application boot, dependency loading, test execution. Run analyze to verify those."

      refute File.exist?(marker), "doctor executed a project source, helper, test, or Rails boot file"
      assert_equal snapshot, tree_snapshot(project), "doctor changed project files or directory contents"
    end
  end

  def test_default_selection_excludes_helpers_fixtures_support_and_non_source_trees
    Dir.mktmpdir("branchproof-doctor-") do |directory|
      marker = File.join(directory, "executed")
      project = File.join(directory, "project")
      create_project(project, marker: marker)
      write(project, "lib/test_helper.rb", "File.write(#{marker.inspect}, 'helper')\n")
      write(project, "lib/fixture.rb", "File.write(#{marker.inspect}, 'fixture')\n")
      write(project, "test/test_helper.rb", "File.write(#{marker.inspect}, 'test helper')\n")
      write(project, "test/support/helper_test.rb", "File.write(#{marker.inspect}, 'support test')\n")
      write(project, "test/fixtures/test_fixture.rb", "File.write(#{marker.inspect}, 'fixture test')\n")
      write(project, "spec/support/shared_spec.rb", "File.write(#{marker.inspect}, 'spec support')\n")
      write(project, "spec/decision_spec.rb", "# RSpec test placeholder\n")
      write(project, "vendor/leak.rb", "File.write(#{marker.inspect}, 'vendor')\n")
      write(project, "tool/leak.rb", "File.write(#{marker.inspect}, 'tool')\n")

      minitest = run_doctor(project, "**/*.rb", "--project", "ruby", "--framework", "minitest", "--format", "json")
      minitest_document = JSON.parse(minitest.fetch(:stdout))

      assert_equal 0, minitest.fetch(:status).exitstatus, minitest.fetch(:stderr)
      assert_equal 4, minitest_document.dig("selection", "source_count")
      assert_equal 1, minitest_document.dig("selection", "test_count")
      assert_equal ["**/*.rb"], minitest_document.dig("selection", "source_patterns")
      assert_equal ["test/**/*_test.rb", "test/**/test_*.rb"], minitest_document.dig("selection", "test_patterns")

      rspec = run_doctor(project, "**/*.rb", "--project", "ruby", "--framework", "rspec", "--format", "json")
      rspec_document = JSON.parse(rspec.fetch(:stdout))
      assert_equal 0, rspec.fetch(:status).exitstatus, rspec.fetch(:stderr)
      assert_equal 4, rspec_document.dig("selection", "source_count")
      assert_equal 1, rspec_document.dig("selection", "test_count")
      assert_equal ["spec/**/*_spec.rb"], rspec_document.dig("selection", "test_patterns")
      refute File.exist?(marker)

      explicit = run_doctor(project, "--project", "ruby", "--framework", "minitest", "--test",
                            "test/test_helper.rb", "--format", "json")
      explicit_document = JSON.parse(explicit.fetch(:stdout))
      assert_equal 0, explicit.fetch(:status).exitstatus, explicit.fetch(:stderr)
      assert_equal 1, explicit_document.dig("selection", "test_count")
      refute File.exist?(marker)
    end
  end

  def test_configuration_defaults_and_command_line_overrides_share_analyze_precedence
    Dir.mktmpdir("branchproof-doctor-") do |directory|
      project = File.join(directory, "project")
      create_project(project)
      write(project, "src/selected.rb", "true\n")
      write(project, "checks/selected_test.rb", "# test\n")
      write(project, "spec/selected_spec.rb", "# spec\n")
      write(project, ".branchproof.json", JSON.generate(
                                            schema_version: 1,
                                            project: "ruby",
                                            framework: "minitest",
                                            sources: ["src/**/*.rb"],
                                            tests: ["checks/*_test.rb"],
                                            exclude: ["src/excluded.rb"],
                                            minimum: { mcdc: 77 },
                                            minimum_changed: { decision: 90 }
                                          ))

      configured = run_doctor(project, "--format", "json")
      config_document = JSON.parse(configured.fetch(:stdout))
      assert_equal "ready", config_document.fetch("status")
      assert_equal File.realpath(File.join(project, ".branchproof.json")), config_document.dig("configuration", "path")
      assert_equal ["src/**/*.rb"], config_document.dig("selection", "source_patterns")
      assert_equal ["checks/*_test.rb"], config_document.dig("selection", "test_patterns")
      assert_equal({ "mcdc" => 77 }, config_document.dig("configuration", "minimum"))
      assert_equal({ "decision" => 90 }, config_document.dig("configuration", "minimum_changed"))

      overridden = run_doctor(project, "lib/**/*.rb", "--test", "test/**/*_test.rb", "--project", "ruby",
                              "--framework", "minitest", "--format", "json")
      override_document = JSON.parse(overridden.fetch(:stdout))
      assert_equal "ready", override_document.fetch("status")
      assert_equal ["lib/**/*.rb"], override_document.dig("selection", "source_patterns")
      assert_equal ["test/**/*_test.rb"], override_document.dig("selection", "test_patterns")

      disabled = run_doctor(project, "--no-config", "--project", "ruby", "--framework", "minitest", "--format", "json")
      disabled_document = JSON.parse(disabled.fetch(:stdout))
      assert_equal "disabled", disabled_document.dig("configuration", "state")
      assert_equal ["lib/**/*.rb", "app/**/*.rb"], disabled_document.dig("selection", "source_patterns")
    end
  end

  def test_doctor_blocks_empty_selection_ambiguous_framework_and_invalid_rails_layout
    Dir.mktmpdir("branchproof-doctor-") do |directory|
      project = File.join(directory, "project")
      create_project(project)
      write(project, "spec/decision_spec.rb", "# spec\n")

      empty_sources = run_doctor(project, "missing/**/*.rb", "--project", "ruby", "--framework", "minitest", "--format", "json")
      assert_blocked_json(empty_sources, expected_check: "source")

      empty_tests = run_doctor(project, "--test", "missing/**/*_test.rb", "--project", "ruby", "--framework", "minitest", "--format", "json")
      assert_blocked_json(empty_tests, expected_check: "test")

      ambiguous = run_doctor(project, "--project", "ruby", "--framework", "auto", "--format", "json")
      assert_blocked_json(ambiguous, expected_check: "setup")

      invalid_rails = run_doctor(project, "--project", "rails", "--framework", "minitest", "--format", "json")
      assert_blocked_json(invalid_rails, expected_check: "setup")
    end
  end

  def test_config_errors_and_forbidden_options_are_parseable_json_even_when_format_follows_error
    Dir.mktmpdir("branchproof-doctor-") do |directory|
      project = File.join(directory, "project")
      create_project(project)
      write(project, "broken.json", "{\n")

      [
        ["--config", "missing.json", "--format", "json"],
        ["--config", "broken.json", "--format", "json"],
        ["--output", "report.json", "--format", "json"],
        ["--level", "3", "--format", "json"],
        ["--", "--seed", "1", "--format", "json"]
      ].each do |options|
        result = run_doctor(project, *options)
        assert_blocked_json(result)
      end
    end
  end

  def test_help_bypasses_project_inspection_and_json_errors_write_only_to_stdout
    Dir.mktmpdir("branchproof-doctor-") do |directory|
      project = File.join(directory, "project")
      FileUtils.mkdir_p(project)
      before = tree_snapshot(project)

      help = run_doctor(project, "--help")
      assert_equal 0, help.fetch(:status).exitstatus
      assert_includes help.fetch(:stdout), "branchproof doctor"
      assert_empty help.fetch(:stderr)
      assert_equal before, tree_snapshot(project)

      invalid = run_doctor(project, "--output", "out.json", "--format", "json")
      assert_equal 2, invalid.fetch(:status).exitstatus
      assert_empty invalid.fetch(:stderr)
      assert_equal "blocked", JSON.parse(invalid.fetch(:stdout)).fetch("status")
    end
  end

  def test_in_process_doctor_preserves_environment_load_path_and_framework_loading
    Dir.mktmpdir("branchproof-doctor-") do |directory|
      project = File.join(directory, "project")
      create_project(project)
      snapshot = tree_snapshot(project)
      script = <<~RUBY
        require "json"
        require "stringio"
        require "branchproof"
        before_env = ENV.to_h
        before_load_path = $LOAD_PATH.dup
        before_features = $LOADED_FEATURES.dup
        before_constants = Object.constants
        stdout = StringIO.new
        stderr = StringIO.new
        status = Branchproof::CLI.new(stdout: stdout, stderr: stderr).call(%w[doctor --project ruby --framework minitest --format json])
        abort "doctor returned \#{status}: \#{stderr.string}" unless status.zero?
        abort "doctor changed ENV" unless ENV.to_h == before_env
        abort "doctor changed $LOAD_PATH" unless $LOAD_PATH == before_load_path
        abort "doctor loaded Minitest" if Object.const_defined?(:Minitest, false) && !before_constants.include?(:Minitest)
        abort "doctor loaded RSpec" if Object.const_defined?(:RSpec, false) && !before_constants.include?(:RSpec)
        after_framework_features = $LOADED_FEATURES - before_features
        framework_features = after_framework_features.grep(%r{(?:^|/)(?:minitest|rspec)(?:/|[.]rb)})
        abort "doctor required a framework: \#{framework_features.inspect}" unless framework_features.empty?
        puts JSON.generate(status: status, document: JSON.parse(stdout.string))
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{File.join(ROOT, "lib")}", "-e", script, chdir: project)

      assert status.success?, stderr
      assert_equal "ready", JSON.parse(stdout).dig("document", "status")
      assert_equal snapshot, tree_snapshot(project), "in-process doctor changed project files or directory contents"
    end
  end

  private

  def create_project(root, marker: nil, rails: false)
    FileUtils.mkdir_p([File.join(root, "lib"), File.join(root, "test")])
    marker_write = marker ? "File.write(#{marker.inspect}, 'source')\n" : "true\n"
    write(root, "lib/decision.rb", "#{marker_write}if true && false\n  :yes\nelse\n  :no\nend\n")
    write(root, "test/decision_test.rb", "# Minitest test placeholder\n")
    write(root, "lib/broken.rb", "def invalid(\n")
    return unless rails

    write(root, "config/application.rb", "File.write(#{marker.inspect}, 'application')\n")
    write(root, "config/environment.rb", "File.write(#{marker.inspect}, 'boot')\n")
  end

  def write(root, relative_path, contents)
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  def run_doctor(project, *arguments)
    Open3.capture3(RbConfig.ruby, EXECUTABLE, "doctor", *arguments, chdir: project).then do |stdout, stderr, status|
      { stdout: stdout, stderr: stderr, status: status }
    end
  end

  def assert_blocked_json(result, expected_check: nil)
    assert_equal 2, result.fetch(:status).exitstatus, result.fetch(:stderr)
    assert_empty result.fetch(:stderr)
    document = JSON.parse(result.fetch(:stdout))
    assert_equal 1, document.fetch("schema_version")
    assert_equal "doctor", document.fetch("command")
    assert_equal "blocked", document.fetch("status")
    refute_empty document.fetch("checks")
    return unless expected_check

    assert(document.fetch("checks").any? { |check| check.fetch("code").include?(expected_check) }, document.fetch("checks").inspect)
  end

  def tree_snapshot(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort.each_with_object({}) do |relative, snapshot|
      next if [".", ".."].include?(relative)

      path = File.join(root, relative)
      snapshot[relative] = if File.directory?(path)
                             :directory
                           elsif File.file?(path)
                             File.binread(path)
                           else
                             File.lstat(path).ftype
                           end
    end
  end
end
