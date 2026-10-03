# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"

class TestOptionalFrameworks < Minitest::Test
  ROOT = File.expand_path("..", __dir__).freeze

  def test_packaged_gem_works_with_either_or_neither_test_framework
    specification = Gem::Specification.load(File.join(ROOT, "branchproof.gemspec"))
    assert_equal ["prism"], specification.runtime_dependencies.map(&:name)

    Dir.mktmpdir("branchproof-consumer-") do |directory|
      archive = build_archive(directory, specification)
      source, minitest_file, rspec_file = write_fixture_project(directory)
      roots = %w[minitest rspec none].to_h do |framework|
        [framework, install_consumer(archive, directory, framework == "none" ? [] : [framework])]
      end

      assert_framework_presence(roots.fetch("minitest"), present: ["minitest"], absent: ["rspec-core"])
      assert_framework_presence(roots.fetch("rspec"), present: ["rspec-core"], absent: ["minitest"])
      assert_framework_presence(roots.fetch("none"), present: [], absent: %w[minitest rspec-core])

      minitest_report = analyze(roots.fetch("minitest"), source, minitest_file, "minitest", directory)
      rspec_report = analyze(roots.fetch("rspec"), source, rspec_file, "rspec", directory)
      assert_successful_analysis(minitest_report)
      assert_successful_analysis(rspec_report)

      assert_offline_commands_work(roots.fetch("none"), directory)
      assert_missing_minitest_is_reported(roots.fetch("none"), source, directory)
      assert_missing_rspec_is_reported(roots.fetch("none"), source, directory)
    end
  end

  private

  def build_archive(directory, specification)
    archive = File.join(directory, specification.file_name)
    capture_io { Gem::Package.build(specification, false, true, archive) }
    archive
  end

  def write_fixture_project(directory)
    project = File.join(directory, "project")
    FileUtils.mkdir_p([File.join(project, "lib"), File.join(project, "test"), File.join(project, "spec")])
    source = File.join(project, "lib", "decision.rb")
    File.write(source, "module ConsumerDecision\n  def self.choose(left, right) = left && right\nend\n")

    minitest_file = File.join(project, "test", "consumer_test.rb")
    File.write(minitest_file, <<~RUBY)
      require "minitest/autorun"
      require "decision"

      class ConsumerTest < Minitest::Test
        def test_true_path
          assert_equal true, ConsumerDecision.choose(true, true)
        end

        def test_false_path
          assert_equal false, ConsumerDecision.choose(false, true)
        end
      end
    RUBY

    rspec_file = File.join(project, "spec", "consumer_spec.rb")
    File.write(rspec_file, <<~RUBY)
      require "decision"

      RSpec.describe ConsumerDecision do
        it "records the true path" do
          expect(described_class.choose(true, true)).to be(true)
        end

        it "records the false path" do
          expect(described_class.choose(false, true)).to be(false)
        end
      end
    RUBY

    [source, minitest_file, rspec_file]
  end

  def install_consumer(archive, directory, frameworks)
    install_root = consumer_root(directory, frameworks)

    _stdout, stderr, status = install_archive(archive, install_root, directory)
    assert status.success?, "isolated package install failed: #{stderr}"
    install_root
  end

  def consumer_root(directory, frameworks, profile = nil)
    profile ||= frameworks.empty? ? "none" : frameworks.first
    install_root = File.join(directory, "gems", profile)
    FileUtils.mkdir_p(install_root)
    (["prism"] + frameworks).each { |name| stage_dependency(name, install_root, {}) }
    install_root
  end

  def install_archive(archive, install_root, directory)
    install_script = <<~RUBY
      require "rubygems/installer"
      Gem::Installer.at(ARGV.fetch(0), install_dir: ARGV.fetch(1), ignore_dependencies: false, wrappers: true).install
    RUBY
    Open3.capture3(clean_environment(install_root), RbConfig.ruby, "-e", install_script, archive, install_root,
                   chdir: directory)
  end

  def stage_dependency(name, install_root, staged)
    return if staged[name]

    specification = Gem.loaded_specs[name] || Gem::Specification.find_by_name(name)
    staged[name] = true
    gem_destination = File.join(install_root, "gems", specification.full_name)
    specification_destination = File.join(install_root, "specifications", File.basename(specification.loaded_from))
    FileUtils.mkdir_p(File.dirname(gem_destination))
    FileUtils.mkdir_p(File.dirname(specification_destination))
    File.symlink(specification.full_gem_path, gem_destination)
    File.symlink(specification.loaded_from, specification_destination)
    cached_package = specification.cache_file
    if File.file?(cached_package)
      FileUtils.mkdir_p(File.join(install_root, "cache"))
      File.symlink(cached_package, File.join(install_root, "cache", File.basename(cached_package)))
    end

    if specification.extensions.any? && File.directory?(specification.extension_dir)
      extension_relative_path = specification.extension_dir.delete_prefix("#{specification.base_dir}/")
      extension_destination = File.join(install_root, extension_relative_path)
      FileUtils.mkdir_p(File.dirname(extension_destination))
      File.symlink(specification.extension_dir, extension_destination)
    end

    specification.runtime_dependencies.each { |dependency| stage_dependency(dependency.name, install_root, staged) }
  end

  def assert_framework_presence(install_root, present:, absent:)
    script = <<~RUBY
      require "rubygems"
      require "branchproof"
      abort "Branchproof loaded outside installed package" unless $LOADED_FEATURES.any? { |path| path.end_with?("/branchproof.rb") && path.include?(ENV.fetch("EXPECTED_INSTALL_ROOT")) }
      abort "Minitest constant loaded" if Object.const_defined?(:Minitest)
      abort "RSpec constant loaded" if Object.const_defined?(:RSpec)
      ENV.fetch("EXPECTED_ABSENT").split(",").each do |name|
        abort "unexpected gem #{name}" unless Gem::Specification.find_all_by_name(name).empty?
      end
    RUBY
    env = clean_environment(install_root).merge(
      "EXPECTED_INSTALL_ROOT" => install_root,
      "EXPECTED_ABSENT" => absent.join(",")
    )
    _stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-e", script)
    assert status.success?, stderr
    present.each do |name|
      assert_operator gem_spec_count(install_root, name), :>, 0, "expected #{name} in isolated profile"
    end
  end

  def gem_spec_count(install_root, name)
    stdout, stderr, status = Open3.capture3(clean_environment(install_root), RbConfig.ruby, "-e",
                                            "require 'rubygems'; print Gem::Specification.find_all_by_name(#{name.inspect}).length")
    assert status.success?, stderr
    stdout.to_i
  end

  def analyze(install_root, source, test_file, framework, directory)
    report = File.join(directory, "#{framework}.json")
    args = [File.join(install_root, "bin", "branchproof"), "analyze", source, "--project", "ruby", "--framework",
            framework, "--test", test_file, "--format", "json", "--output", report]
    _stdout, stderr, status = Open3.capture3(clean_environment(install_root), RbConfig.ruby, *args,
                                             chdir: File.dirname(source, 2))
    assert status.success?, stderr
    JSON.parse(File.read(report))
  end

  def assert_successful_analysis(report)
    assert_equal "PASSED", report.dig("baseline", "status")
    assert_equal true, report.dig("baseline", "finalized")
    assert_equal true, report.dig("completeness", "observation")
    assert_equal true, report.dig("completeness", "analysis")
    observations = report.dig("observations", "tests")
    refute_empty observations
    test_ids = observations.map { |test| test["test_id"] || test["id"] }.compact
    attributed_ids = report.dig("observations", "vectors").flat_map { |vector| Array(vector["test_ids"]) }
    assert test_ids.intersect?(attributed_ids), "expected observation vectors attributed to a recorded test"
  end

  def assert_offline_commands_work(install_root, directory)
    saved = File.join(directory, "minitest.json")
    rendered = File.join(directory, "rendered.html")
    compare = File.join(directory, "compare.json")
    report = File.join(install_root, "bin", "branchproof")

    %w[terminal json].each do |format|
      stdout, stderr, status = Open3.capture3(clean_environment(install_root), RbConfig.ruby, report, "report", saved,
                                              "--format", format)
      assert status.success?, "offline #{format} report failed: #{stderr}\n#{stdout}"
      if format == "terminal"
        assert_includes stdout, "Tests: PASSED"
      else
        rendered_document = JSON.parse(stdout)
        assert_equal "1.4", rendered_document.fetch("schema_version")
        assert_equal "PASSED", rendered_document.dig("baseline", "status")
      end
    end
    assert_saved_report_valid(install_root, saved)
    stdout, stderr, status = Open3.capture3(clean_environment(install_root), RbConfig.ruby, report, "report", saved,
                                            "--format", "html", "--output", rendered)
    assert status.success?, "offline html report failed: #{stderr}\n#{stdout}"
    assert_includes File.read(rendered), "works offline"

    stdout, stderr, status = Open3.capture3(clean_environment(install_root), RbConfig.ruby, report, "compare", saved,
                                            saved, "--format", "json", "--output", compare)
    assert status.success?, "offline comparison failed (exit #{status.exitstatus}): #{stderr}\n#{stdout}"
    comparison = JSON.parse(File.read(compare))
    assert_equal "complete", comparison.fetch("status")
    assert_equal "PASSED", comparison.dig("before", "status")
    assert_equal "PASSED", comparison.dig("after", "status")
  end

  def assert_saved_report_valid(install_root, report_path, expected_status: "PASSED")
    script = <<~RUBY
      require "branchproof"
      report = Branchproof::SavedReport.read(ARGV.fetch(0))
      abort "saved report identity mismatch" unless report.fetch("schema_version") == "1.4"
      abort "saved report baseline status mismatch" unless report.dig("baseline", "status") == ENV.fetch("EXPECTED_STATUS")
    RUBY
    env = clean_environment(install_root).merge("EXPECTED_STATUS" => expected_status)
    _stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-e", script, report_path)
    assert status.success?, "SavedReport.read failed: #{stderr}"
  end

  def assert_missing_minitest_is_reported(install_root, source, directory)
    marker = File.join(directory, "minitest-booted")
    rails_boot_marker = File.join(directory, "rails-environment-booted")
    test_file = File.join(directory, "missing_minitest_test.rb")
    File.write(test_file, "File.write(#{marker.inspect}, 'booted')\n")
    project_root = File.dirname(source, 2)
    config = File.join(project_root, "config")
    FileUtils.mkdir_p(config)
    File.write(File.join(config, "application.rb"), "# Minimal Rails project marker for framework boot ordering.\n")
    File.write(File.join(config, "environment.rb"), "File.write(#{rails_boot_marker.inspect}, 'booted')\n")
    report = File.join(directory, "missing-minitest.json")
    command = [File.join(install_root, "bin", "branchproof"), "analyze", source, "--project", "rails", "--framework",
               "minitest", "--test", test_file, "--format", "json", "--output", report]
    _stdout, stderr, status = Open3.capture3(clean_environment(install_root), RbConfig.ruby, *command,
                                             chdir: project_root)

    assert_equal 2, status.exitstatus, stderr
    refute File.exist?(marker), "test file ran despite missing Minitest"
    refute File.exist?(rails_boot_marker), "Rails environment booted before missing Minitest was diagnosed"
    document = JSON.parse(File.read(report))
    assert_equal "ERROR", document.dig("baseline", "status")
    assert_equal false, document.dig("baseline", "finalized")
    diagnostic = document["diagnostics"].find { |entry| entry.fetch("code") == "minitest_missing" }
    refute_nil diagnostic
    assert_includes diagnostic.fetch("message"), "add minitest >= 5.25.5, < 6 to the application's test bundle"
    assert_equal false, document.dig("completeness", "observation")
    assert_equal false, document.dig("completeness", "analysis")
    assert_saved_report_valid(install_root, report, expected_status: "ERROR")
  end

  def assert_missing_rspec_is_reported(install_root, source, directory)
    marker = File.join(directory, "rspec-booted")
    test_file = File.join(directory, "missing_rspec_spec.rb")
    File.write(test_file, "File.write(#{marker.inspect}, 'booted')\n")
    report = File.join(directory, "missing-rspec.json")
    command = [File.join(install_root, "bin", "branchproof"), "analyze", source, "--project", "ruby", "--framework",
               "rspec", "--test", test_file, "--format", "json", "--output", report]
    _stdout, stderr, status = Open3.capture3(clean_environment(install_root), RbConfig.ruby, *command,
                                             chdir: File.dirname(source, 2))

    assert_equal 2, status.exitstatus, stderr
    refute File.exist?(marker), "test file ran despite missing RSpec"
    document = JSON.parse(File.read(report))
    assert_equal "ERROR", document.dig("baseline", "status")
    assert_equal false, document.dig("baseline", "finalized")
    assert_includes document["diagnostics"].map { |diagnostic| diagnostic.fetch("code") }, "rspec_missing"
  end

  def clean_environment(install_root)
    unset_keys = ENV.keys.select do |key|
      %w[RUBYOPT RUBYLIB].include?(key) || key.start_with?("BUNDLE_", "BUNDLER_", "GEM", "RUBYGEMS_")
    end
    cleared = unset_keys.to_h { |key| [key, nil] }
    ENV.to_h.merge(cleared).merge("GEM_HOME" => install_root, "GEM_PATH" => install_root)
  end
end
