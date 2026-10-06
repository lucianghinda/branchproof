# frozen_string_literal: true

require "test_helper"
require "rubygems"
require "rubygems/package"
require "rubygems/installer"
require "open3"
require "shellwords"
require "tmpdir"
require "yaml"

class TestPackaging < Minitest::Test
  ROOT = File.expand_path("..", __dir__).freeze

  def test_built_gem_installs_both_executable_names
    Dir.mktmpdir("branchproof-package-") do |directory|
      specification = Gem::Specification.load(File.join(ROOT, "branchproof.gemspec"))
      archive = File.join(directory, specification.file_name)
      capture_io { Gem::Package.build(specification, false, true, archive) }
      package = Gem::Package.new(archive)
      %w[branchproof mcdc].each { |name| assert_includes package.contents, "exe/#{name}" }
      assert_includes package.contents, "doc/docs/usage.md"
      %w[decision_syntax flow_instrumentation runtime_flow decision_table constraints].each do |name|
        assert_includes package.contents, "lib/branchproof/#{name}.rb"
      end

      destination = File.join(directory, "installed")
      Gem::Installer.at(archive, install_dir: destination, ignore_dependencies: true, wrappers: true).install
      %w[branchproof mcdc].each do |name|
        assert File.executable?(File.join(destination, "bin", name)), "missing installed executable #{name}"
      end
    end
  end

  def test_gemspec_has_runtime_identity_and_cli
    spec = Gem::Specification.load(File.join(ROOT, "branchproof.gemspec"))

    assert_equal "branchproof", spec.name
    assert_equal Branchproof::VERSION, spec.version.to_s
    refute spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.4.9"))
    assert spec.required_ruby_version.satisfied_by?(Gem::Version.new("4.0.0"))
    assert_includes spec.files, "README.md"
    assert_includes spec.files, "CHANGELOG.md"
    assert_includes spec.files, "LICENSE.txt"
    assert_includes spec.files, "NOTICE"
    assert_includes spec.files, "lib/branchproof.rb"
    assert_includes spec.files, "exe/mcdc"
    assert_includes spec.files, "exe/branchproof"
    assert_includes spec.files, "sig/branchproof.rbs"
    assert_includes spec.files, "doc/Branchproof.md"
    assert_includes spec.files, "llms.txt"
    assert_includes spec.executables, "mcdc"
    assert_includes spec.executables, "branchproof"
  end

  def test_package_uses_apache_license
    spec = Gem::Specification.load(File.join(ROOT, "branchproof.gemspec"))
    readme = File.read(File.join(ROOT, "README.md"))

    assert_equal "Apache-2.0", spec.license
    assert_includes readme, "Apache License, Version 2.0"
    assert_includes readme, "(LICENSE.txt)"
  end

  def test_readme_links_to_the_detailed_command_reference
    readme = File.read(File.join(ROOT, "README.md"))
    usage = File.read(File.join(ROOT, "docs/usage.md"))

    assert_includes readme, "docs/usage.md"
    %w[analyze --test --level --minimum].each { |token| assert_includes readme, token }

    %w[mcdc analyze --project --level --format --output --limits].each do |token|
      assert_includes usage, token
    end
    assert_includes usage, "-- --seed"
    assert_includes usage, "test/**/*_test.rb"
    assert_includes usage, "test/**/test_*.rb"
    assert_includes usage, "DISABLE_BOOTSNAP=1"
    assert_includes usage, "Rails 8.1"
    refute_includes readme, "TODO:"
    refute_includes usage, "TODO:"
  end

  def test_rails_is_not_a_runtime_dependency
    spec = Gem::Specification.load(File.join(ROOT, "branchproof.gemspec"))

    refute(spec.runtime_dependencies.any? { |dependency| %w[rails railties].include?(dependency.name) })
    refute(spec.runtime_dependencies.any? { |dependency| dependency.name == "minitest" })
  end

  def test_rbs_and_ci_cover_the_supported_runtime
    rbs = File.read(File.join(ROOT, "sig/branchproof.rbs"))
    workflow = File.read(File.join(ROOT, ".github/workflows/main.yml"))
    workflow_document = YAML.safe_load(workflow, aliases: true)
    ruby_steps = workflow_document.fetch("jobs").values.flat_map { |job| job.fetch("steps") }.select do |step|
      step["uses"] == "ruby/setup-ruby@v1"
    end

    assert_includes rbs, "class Source"
    assert_includes rbs, "class Report"
    refute_empty ruby_steps
    ruby_steps.each { |step| assert_equal "4.0", step.fetch("with").fetch("ruby-version") }
    assert_includes workflow, "bundle exec rake"
    assert_includes workflow, "BRANCHPROOF_RAILS_INTEGRATION: \"1\""
    assert_includes workflow, "Rails 8.1"
  end

  def test_rspec_core_workflow_command_is_shell_safe_and_checks_the_resolved_version
    workflow = YAML.safe_load_file(File.join(ROOT, ".github/workflows/main.yml"), aliases: true)
    step = workflow.fetch("jobs").fetch("rspec-compatibility").fetch("steps").find do |candidate|
      candidate["name"] == "Verify resolved RSpec Core version"
    end
    argv = Shellwords.split(step.fetch("run"))
    expected = Gem.loaded_specs.fetch("rspec-core").version.to_s
    _stdout, stderr, status = Open3.capture3({ "EXPECTED_RSPEC_CORE_VERSION" => expected }, *argv, chdir: ROOT)
    assert status.success?, stderr
    _stdout, stderr, status = Open3.capture3({ "EXPECTED_RSPEC_CORE_VERSION" => "0.0.0" }, *argv, chdir: ROOT)
    refute status.success?
    assert_includes stderr, "unexpected RSpec core #{expected}"
  end
end
