# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class ProjectAcceptanceTest < Minitest::Test
  GEM_ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.join(GEM_ROOT, "exe", "mcdc")

  def test_plain_ruby_project_discovers_both_minitest_filename_conventions_once
    project = build_project
    write_project_files(project, <<~RUBY)
      class AlphaTest < Minitest::Test
        def test_alpha
          File.open(ENV.fetch("BRANCHPROOF_BODY_LOG"), "a") { |file| file.puts "alpha" }
          assert_equal :yes, branchproof_value(true)
        end
      end
    RUBY
    write_file(project, "test/test_beta.rb", <<~RUBY)
      require "test_helper"

      class BetaTest < Minitest::Test
        def test_beta
          File.open(ENV.fetch("BRANCHPROOF_BODY_LOG"), "a") { |file| file.puts "beta" }
          assert_equal :yes, branchproof_value(true)
        end
      end
    RUBY
    write_file(project, "test/support/should_not_run_test.rb", <<~RUBY)
      raise "default discovery executed test/support"
    RUBY
    write_file(project, "test/fixtures/should_not_run_test.rb", <<~RUBY)
      raise "default discovery executed test/fixtures"
    RUBY

    result = run_project(project)

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    assert_equal "PASSED", result.fetch(:json).dig("baseline", "status")
    assert_equal 2, result.fetch(:json).dig("baseline", "executed_tests")
    assert_equal %w[alpha beta], File.readlines(project.fetch(:body_log), chomp: true).sort
    assert_equal ["loaded"], File.readlines(project.fetch(:helper_log), chomp: true)
  ensure
    cleanup_project(project)
  end

  def test_explicit_support_test_bypasses_default_exclusions
    project = build_project
    write_project_files(project, <<~RUBY)
      class ExplicitSupportTest < Minitest::Test
        def test_support_is_selected
          File.write(ENV.fetch("BRANCHPROOF_EXPLICIT_LOG"), "ran")
          assert true
        end
      end
    RUBY
    write_file(project, "test/support/explicit_test.rb", <<~RUBY)
      require "test_helper"
      #{File.read(File.join(project.fetch(:root), "test", "project_test.rb"))}
    RUBY

    result = run_project(project, tests: ["test/support/explicit_test.rb"])

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    assert_equal 1, result.fetch(:json).dig("baseline", "executed_tests")
    assert_equal "ran", File.read(project.fetch(:explicit_log))
  ensure
    cleanup_project(project)
  end

  def test_project_modes_and_auto_detection_are_visible_through_the_cli
    project = build_project
    write_project_files(project, <<~RUBY)
      class ProjectModeTest < Minitest::Test
        def test_ruby_mode
          assert_equal :yes, branchproof_value(true)
        end
      end
    RUBY

    ruby_result = run_project(project, args: ["--project", "ruby"])
    assert_equal 0, ruby_result[:status].exitstatus, ruby_result[:stderr]
    assert_equal "ruby", ruby_result.fetch(:json).dig("baseline", "project", "kind")

    write_file(project, "config/application.rb", "# Rails marker\n")
    write_file(project, "config/environment.rb", "raise 'auto Rails boot reached'\n")
    auto_result = run_project(project, args: ["--project", "auto"])
    assert_equal 2, auto_result[:status].exitstatus, auto_result[:stderr]
    assert_equal "ERROR", auto_result.fetch(:json).dig("baseline", "status")

    forced_result = run_project(project, args: ["--project", "rails"])
    assert_equal 2, forced_result[:status].exitstatus, forced_result[:stderr]
  ensure
    cleanup_project(project)
  end

  def test_child_uses_project_lib_and_test_load_paths_and_preserves_parent_environment
    project = build_project
    write_project_files(project, <<~RUBY)
      require "project_helper"

      class LoadPathTest < Minitest::Test
        def test_project_paths_and_environment
          assert_equal :from_lib, project_value
          assert_equal :from_test, test_helper_value
          assert_equal "parent-value", ENV.fetch("BRANCHPROOF_PARENT_VALUE")
        end
      end
    RUBY
    write_file(project, "lib/project_helper.rb", "def project_value\n  :from_lib\nend\n")
    write_file(project, "test/test_helper.rb", <<~RUBY)
      require "minitest/autorun"
      def test_helper_value
        :from_test
      end
    RUBY

    previous = ENV.fetch("BRANCHPROOF_PARENT_VALUE", nil)
    ENV["BRANCHPROOF_PARENT_VALUE"] = "parent-value"
    result = run_project(project)

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    assert_equal "PASSED", result.fetch(:json).dig("baseline", "status")
    assert_equal "parent-value", ENV.fetch("BRANCHPROOF_PARENT_VALUE")
  ensure
    previous.nil? ? ENV.delete("BRANCHPROOF_PARENT_VALUE") : ENV["BRANCHPROOF_PARENT_VALUE"] = previous
    cleanup_project(project)
  end

  def test_runner_tokens_are_observable_before_minitest_parses_them
    project = build_project
    write_project_files(project, <<~RUBY)
      File.write(ENV.fetch("BRANCHPROOF_ARGS_LOG"), JSON.generate(ARGV))

      class FilteredTest < Minitest::Test
        def test_selected
          assert true
        end

        def test_not_selected
          flunk "-n did not filter this test"
        end
      end
    RUBY
    result = run_project(project, runner_args: ["-n", "/test_selected/", "--seed", "4242"])

    assert_equal 0, result[:status].exitstatus, result[:stderr]
    assert_equal ["-n", "/test_selected/", "--seed", "4242"], JSON.parse(File.read(project.fetch(:args_log)))
    assert_equal 1, result.fetch(:json).dig("baseline", "executed_tests")
    assert_equal 4242, result.fetch(:json).dig("baseline", "seed")
  ensure
    cleanup_project(project)
  end

  def test_each_analysis_level_snapshots_a_single_test_run
    [1, 2, 3].each do |level|
      project = build_project
      write_project_files(project, <<~RUBY)
        class OneRunTest < Minitest::Test
          def test_once
            File.open(ENV.fetch("BRANCHPROOF_BODY_LOG"), "a") { |file| file.puts "run" }
            assert_equal :yes, branchproof_value(true)
          end
        end
      RUBY

      result = run_project(project, args: ["--level", level.to_s])

      assert_equal 0, result[:status].exitstatus, "level #{level}: #{result[:stderr]}"
      assert_equal 1, result.fetch(:json).dig("baseline", "executed_tests"), "level #{level} count"
      assert_equal ["run"], File.readlines(project.fetch(:body_log), chomp: true), "level #{level} reran the suite"
    ensure
      cleanup_project(project)
    end
  end

  def test_configured_selection_and_exclusion_match_equivalent_cli_selection
    project = build_project
    write_project_files(project, <<~RUBY)
      class ConfiguredProjectTest < Minitest::Test
        def test_configured_selection
          assert_equal :yes, branchproof_value(true)
        end
      end
    RUBY
    write_file(project, "lib/generated.rb", <<~RUBY)
      def generated_decision(value)
        value && value
      end
    RUBY
    write_file(project, "config/policy.json", JSON.generate(
                                                schema_version: 1,
                                                sources: ["lib/**/*.rb"],
                                                tests: ["test/project_test.rb"],
                                                exclude: ["lib/generated.rb"]
                                              ))

    configured = run_project(project, args: ["--config", "config/policy.json"], source_args: [])
    explicit = run_project(project, args: ["--test", "test/project_test.rb"], source_args: ["lib/decision.rb"])

    assert_equal 0, configured[:status].exitstatus, configured[:stderr]
    assert_equal 0, explicit[:status].exitstatus, explicit[:stderr]
    configured_sources = configured[:json].fetch("source_inventory").fetch("source_units").map { |unit| unit.fetch("relative_path") }
    assert_equal ["lib/decision.rb"], configured_sources
    assert_equal ["lib/**/*.rb"], configured[:json].dig("run_metadata", "source_patterns")
    assert_equal ["lib/generated.rb"], configured[:json].dig("run_metadata", "excluded_files")
    assert_equal ["lib/decision.rb"], configured[:json].dig("run_metadata", "selected_source_files")
    assert_equal explicit[:json].fetch("source_inventory").fetch("source_units").map { |unit| unit.fetch("relative_path") },
                 configured_sources
  ensure
    cleanup_project(project)
  end

  private

  def build_project
    root = Dir.mktmpdir("branchproof-project-acceptance-")
    project = {
      root: root,
      body_log: File.join(root, "body.log"),
      helper_log: File.join(root, "helper.log"),
      explicit_log: File.join(root, "explicit.log"),
      args_log: File.join(root, "args.json")
    }
    %w[lib test/support test/fixtures].each { |path| FileUtils.mkdir_p(File.join(root, path)) }
    write_file(project, "lib/decision.rb", <<~RUBY)
      def branchproof_value(value)
        if value
          :yes
        else
          :no
        end
      end
    RUBY
    write_file(project, "test/test_helper.rb", <<~RUBY)
      File.open(ENV.fetch("BRANCHPROOF_HELPER_LOG"), "a") { |file| file.puts "loaded" }
      require "minitest/autorun"
    RUBY
    project
  end

  def write_project_files(project, test_source)
    write_file(project, "test/project_test.rb", "require \"test_helper\"\nrequire \"decision\"\n#{test_source}")
  end

  def write_file(project, relative_path, content)
    path = File.join(project.fetch(:root), relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  def run_project(project, args: [], tests: nil, runner_args: [], source_args: nil)
    test_args = tests || []
    source_args ||= [File.join(project.fetch(:root), "lib", "decision.rb")]
    cli_args = ["analyze", *source_args, "--format", "json"]
    test_args.each { |path| cli_args.push("--test", File.join(project.fetch(:root), path)) } unless test_args.empty?
    cli_args.concat(args)
    cli_args.push("--", *runner_args) unless runner_args.empty?
    env = {
      "MT_NO_PLUGINS" => "1",
      "BRANCHPROOF_BODY_LOG" => project.fetch(:body_log),
      "BRANCHPROOF_HELPER_LOG" => project.fetch(:helper_log),
      "BRANCHPROOF_EXPLICIT_LOG" => project.fetch(:explicit_log),
      "BRANCHPROOF_ARGS_LOG" => project.fetch(:args_log)
    }
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, EXECUTABLE, *cli_args, chdir: project.fetch(:root))
    json = JSON.parse(stdout)
    { stdout: stdout, stderr: stderr, status: status, json: json }
  end

  def cleanup_project(project)
    FileUtils.remove_entry(project.fetch(:root)) if project && File.directory?(project.fetch(:root))
  end
end
