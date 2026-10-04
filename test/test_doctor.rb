# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "branchproof/cli"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

class TestDoctor < Minitest::Test
  def test_doctor_returns_structured_static_result_without_inventorying_sources
    Dir.mktmpdir do |root|
      create_project(root)
      stdout = StringIO.new
      stderr = StringIO.new
      cli = Branchproof::CLI.new(stdout: stdout, stderr: stderr)
      source = Object.new
      source.define_singleton_method(:inventory) { |**_args| flunk "doctor must not inventory source files" }

      status = Gem.stub(:loaded_specs, { "minitest" => gem_spec("5.25.5") }) do
        Branchproof::Source.stub(:new, source) do
          cli.stub(:run_worker, ->(*) { flunk "doctor must not run the worker" }) do
            Dir.chdir(root) { cli.call(%w[doctor --project ruby --framework minitest --format json]) }
          end
        end
      end

      assert_equal 0, status
      assert_empty stderr.string
      document = JSON.parse(stdout.string)
      assert_equal 1, document.fetch("schema_version")
      assert_equal "doctor", document.fetch("command")
      assert_equal "ready", document.fetch("status")
      assert_equal File.expand_path(".branchproof.json", File.realpath(root)), document.dig("configuration", "path")
      assert_equal "ruby", document.dig("runtime", "engine")
      refute_empty document.dig("runtime", "version")
      assert_equal "minitest", document.dig("framework", "name")
      assert_equal 1, document.dig("selection", "source_count")
      assert_equal 1, document.dig("selection", "test_count")
      assert_includes document.fetch("limitations").join(" "), "boot"
    end
  end

  def test_doctor_help_does_not_inspect_project
    stdout = StringIO.new
    stderr = StringIO.new

    status = Branchproof::CLI.new(stdout: stdout, stderr: stderr).call(%w[doctor --help])

    assert_equal 0, status
    assert_empty stderr.string
    assert_includes stdout.string, "branchproof doctor"
  end

  def test_doctor_uses_configuration_for_project_patterns_exclusions_and_minima
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "src"))
      FileUtils.mkdir_p(File.join(root, "checks"))
      File.write(File.join(root, "src", "app.rb"), "true\n")
      File.write(File.join(root, "src", "generated.rb"), "true\n")
      File.write(File.join(root, "checks", "app_test.rb"), "# static file\n")
      File.write(File.join(root, ".branchproof.json"), JSON.generate(
                                                         schema_version: 1,
                                                         project: "ruby",
                                                         framework: "minitest",
                                                         sources: ["src/**/*.rb"],
                                                         tests: ["checks/*_test.rb"],
                                                         exclude: ["src/generated.rb"],
                                                         minimum: { mcdc: 0 }
                                                       ))
      stdout = StringIO.new
      cli = Branchproof::CLI.new(stdout: stdout, stderr: StringIO.new)
      status = Gem.stub(:loaded_specs, { "minitest" => gem_spec("5.27.0") }) do
        Dir.chdir(root) { cli.call(%w[doctor --format json]) }
      end

      result = JSON.parse(stdout.string)
      assert_equal 0, status
      assert_equal "ready", result.fetch("status")
      assert_equal "loaded", result.dig("configuration", "state")
      assert_equal File.realpath(File.join(root, ".branchproof.json")), result.dig("configuration", "path")
      assert_equal({ "mcdc" => 0 }, result.dig("configuration", "minimum"))
      assert_equal ["src/**/*.rb"], result.dig("selection", "source_patterns")
      assert_equal ["checks/*_test.rb"], result.dig("selection", "test_patterns")
      assert_equal ["src/generated.rb"], result.dig("selection", "excludes")
      assert_equal 1, result.dig("selection", "source_count")
    end
  end

  def test_doctor_json_reports_configuration_and_ambiguous_project_errors
    Dir.mktmpdir do |root|
      File.write(File.join(root, "invalid.json"), JSON.generate(schema_version: 1, unknown: true))
      FileUtils.mkdir_p(File.join(root, "test"))
      FileUtils.mkdir_p(File.join(root, "spec"))
      File.write(File.join(root, "test", "example_test.rb"), "# test\n")
      File.write(File.join(root, "spec", "example_spec.rb"), "# spec\n")

      [["--config", "invalid.json"], ["--no-config"]].each do |options|
        stdout = StringIO.new
        status = Dir.chdir(root) do
          Branchproof::CLI.new(stdout: stdout, stderr: StringIO.new).call(["doctor", "--format", "json", *options])
        end

        result = JSON.parse(stdout.string)
        assert_equal 2, status
        assert_equal "blocked", result.fetch("status")
        assert(result.fetch("checks").any? { |check| check.fetch("status") == "error" })
      end
    end
  end

  def test_doctor_json_keeps_invalid_argument_errors_parseable
    stdout = StringIO.new
    stderr = StringIO.new

    status = Branchproof::CLI.new(stdout: stdout, stderr: stderr).call(%w[doctor --format json --output out.json])

    assert_equal 2, status
    assert_empty stderr.string
    document = JSON.parse(stdout.string)
    assert_equal "blocked", document.fetch("status")
    assert(document.fetch("checks").any? { |check| check.fetch("status") == "error" })
  end

  def test_doctor_rejects_directory_only_source_and_test_globs
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      stdout = StringIO.new
      status = Dir.chdir(root) do
        Branchproof::CLI.new(stdout: stdout, stderr: StringIO.new).call(%w[doctor lib test --test test --format json])
      end

      assert_equal 2, status
      result = JSON.parse(stdout.string)
      assert_equal "blocked", result.fetch("status")
      assert(result.fetch("checks").any? { |check| check.fetch("status") == "error" })
    end
  end

  def test_doctor_prefers_activated_framework_metadata_to_visible_versions
    activated = gem_spec("5.20.0")
    discoverable = gem_spec("5.27.0")
    doctor = Branchproof::Doctor.new(options: doctor_options,
                                     gem_sources: { activated: { "minitest" => activated },
                                                    discoverable: ->(_name) { [discoverable] } })

    result = doctor.document(source_files: ["lib/app.rb"], test_files: ["test/app_test.rb"])

    assert_equal "activated", result.dig(:framework, :availability)
    assert_equal "5.20.0", result.dig(:framework, :version)
    refute_equal "ready", result.fetch(:status)
    assert_includes result.fetch(:checks).find { |check| check[:code] == "framework" }[:message], "current test bundle"
  end

  def test_doctor_warns_about_already_loaded_bootsnap_without_blocking
    doctor = Branchproof::Doctor.new(options: doctor_options,
                                     gem_sources: { activated: {},
                                                    discoverable: ->(_name) { [gem_spec("5.27.0"), gem_spec("5.26.0")] } },
                                     loaded_features: ["bootsnap/setup.rb"])

    result = doctor.document(source_files: ["lib/app.rb"], test_files: ["test/app_test.rb"])

    assert_equal "ready", result.fetch(:status)
    assert_equal "5.27.0", result.dig(:framework, :version)
    assert(result.fetch(:checks).any? { |check| check[:code] == "loaded_runtime" && check[:status] == "warning" })
  end

  def test_warning_only_terminal_result_exits_successfully
    Dir.mktmpdir do |root|
      create_project(root)
      stdout = StringIO.new
      feature = "bootsnap/setup.rb"
      $LOADED_FEATURES << feature
      status = Gem.stub(:loaded_specs, { "minitest" => gem_spec("5.27.0") }) do
        Dir.chdir(root) do
          Branchproof::CLI.new(stdout: stdout, stderr: StringIO.new).call(%w[doctor --project ruby --framework minitest])
        end
      end

      assert_equal 0, status
      assert_includes stdout.string, "WARNING: Bootsnap already loaded"
      assert_includes stdout.string, "Static-only: Static checks only:"
      assert_includes stdout.string, "application boot"
    ensure
      $LOADED_FEATURES.delete(feature)
    end
  end

  def test_doctor_reports_missing_selected_framework_with_actionable_requirement
    doctor = Branchproof::Doctor.new(options: doctor_options,
                                     gem_sources: { activated: {}, discoverable: ->(_name) { [] } })

    result = doctor.document(source_files: ["lib/app.rb"], test_files: ["test/app_test.rb"])
    message = result.fetch(:checks).find { |check| check[:code] == "framework" }[:message]

    assert_equal "blocked", result.fetch(:status)
    assert_includes message, ">= 5.25.5, < 7"
    assert_includes message, "current test bundle"
  end

  def test_doctor_uses_rspec_core_requirement_without_loading_rspec
    options = doctor_options(framework: "rspec")
    doctor = Branchproof::Doctor.new(options: options,
                                     gem_sources: { activated: {},
                                                    discoverable: ->(_name) { [framework_spec("rspec-core", "3.13.2")] } })

    result = doctor.document(source_files: ["lib/app.rb"], test_files: ["spec/app_spec.rb"])

    assert_equal "ready", result.fetch(:status)
    assert_equal "discoverable", result.dig(:framework, :availability)
    assert_equal "~> 3.13.0", result.dig(:framework, :requirement)
  end

  def test_doctor_blocks_runtimes_and_framework_versions_outside_exact_supported_ranges
    cases = [
      ["ruby", "3.4.7", "minitest", "5.27.0", "minitest"],
      ["ruby", "4.0.1", "minitest", "7.0.0", "minitest"],
      ["ruby", "4.0.1", "rspec", "3.14.0", "rspec-core"],
      ["ruby", "4.0.1", "rspec", "3.14.0.pre", "rspec-core"],
      ["jruby", "4.0.1", "minitest", "5.27.0", "minitest"]
    ]
    cases.each do |engine, ruby_version, framework, gem_version, gem_name|
      options = doctor_options(framework: framework)
      doctor = Branchproof::Doctor.new(options: options,
                                       runtime: { engine: engine, version: ruby_version },
                                       gem_sources: { activated: { gem_name => framework_spec(gem_name, gem_version) },
                                                      discoverable: ->(_name) { [] } })

      result = doctor.document(source_files: ["lib/app.rb"], test_files: ["test/app_test.rb"])

      assert_equal "blocked", result.fetch(:status), "#{engine} #{ruby_version} with #{framework} #{gem_version}"
    end
  end

  def test_doctor_accepts_minitest_six
    doctor = Branchproof::Doctor.new(options: doctor_options(framework: "minitest"),
                                     runtime: { engine: "ruby", version: "4.0.1" },
                                     gem_sources: { activated: { "minitest" => framework_spec("minitest", "6.0.6") },
                                                    discoverable: ->(_name) { [] } })

    result = doctor.document(source_files: ["lib/app.rb"], test_files: ["test/app_test.rb"])

    assert_equal "ready", result.fetch(:status)
    assert_equal "6.0.6", result.dig(:framework, :version)
  end

  def test_analyze_source_selection_keeps_sorted_unique_canonical_safety_exclusions
    Dir.mktmpdir do |root|
      %w[lib test spec tool vendor].each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
      %w[lib/also_keep.rb lib/keep.rb lib/config_excluded.rb lib/loaded.rb test/suite_test.rb spec/leak.rb tool/leak.rb vendor/leak.rb].each do |path|
        File.write(File.join(root, path), "true\n")
      end
      File.symlink("config_excluded.rb", File.join(root, "lib", "config_alias.rb"))
      File.symlink("../test/suite_test.rb", File.join(root, "lib", "test_alias.rb"))
      File.symlink("loaded.rb", File.join(root, "lib", "loaded_alias.rb"))
      config_path = File.join(root, ".branchproof.json")
      File.write(config_path, JSON.generate(schema_version: 1, exclude: ["lib/config_excluded.rb"]))
      loaded_path = File.realpath(File.join(root, "lib", "loaded.rb"))
      $LOADED_FEATURES << loaded_path
      cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)
      options = Dir.chdir(root) do
        cli.send(:parse, ["analyze", "lib/*.rb", "lib/**/*.rb", "--test", "test/suite_test.rb"])
      end

      selected = Dir.chdir(root) { cli.send(:select_source_files, options) }
      metadata = cli.send(:run_metadata, options, {})

      assert_equal ["lib/also_keep.rb", "lib/keep.rb"], metadata[:selected_source_files]
      assert_equal ["lib/config_excluded.rb"], metadata[:excluded_files]
      assert_equal selected.sort.uniq, selected
      assert_same selected, options[:selected_source_files]
      assert_equal [File.expand_path("lib/config_excluded.rb", File.realpath(root))], options[:excluded_files]
    ensure
      $LOADED_FEATURES.delete(loaded_path)
    end
  end

  private

  def create_project(root)
    FileUtils.mkdir_p(File.join(root, "lib"))
    FileUtils.mkdir_p(File.join(root, "test"))
    File.write(File.join(root, "lib", "app.rb"), "def ready? = true\n")
    File.write(File.join(root, "test", "app_test.rb"), "# static test placeholder\n")
  end

  def gem_spec(version)
    framework_spec("minitest", version)
  end

  def framework_spec(name, version)
    Gem::Specification.new(name, version)
  end

  def doctor_options(framework: "minitest")
    {
      project: { kind: "ruby", root: Dir.pwd, framework: framework },
      configuration: nil,
      config_disabled: false,
      source_patterns: ["lib/**/*.rb"],
      test_patterns: ["test/**/*_test.rb"],
      exclude: []
    }
  end
end
