# frozen_string_literal: true

require "test_helper"
require "rubygems"
require "rubygems/package"
require "rubygems/installer"
require "tmpdir"

class TestPackaging < Minitest::Test
  ROOT = File.expand_path("..", __dir__).freeze

  def test_built_gem_installs_both_executable_names
    Dir.mktmpdir("branchproof-package-") do |directory|
      specification = Gem::Specification.load(File.join(ROOT, "branchproof.gemspec"))
      archive = File.join(directory, specification.file_name)
      capture_io { Gem::Package.build(specification, false, true, archive) }
      package = Gem::Package.new(archive)
      %w[branchproof mcdc].each { |name| assert_includes package.contents, "exe/#{name}" }
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

  def test_readme_documents_real_command_surface
    readme = File.read(File.join(ROOT, "README.md"))

    %w[mcdc analyze --project --level --format --output --limits].each do |token|
      assert_includes readme, token
    end
    assert_includes readme, "-- --seed"
    assert_includes readme, "test/**/*_test.rb"
    assert_includes readme, "test/**/test_*.rb"
    assert_includes readme, "DISABLE_BOOTSNAP=1"
    assert_includes readme, "Rails 8.1"
    refute_includes readme, "TODO:"
  end

  def test_rails_is_not_a_runtime_dependency
    spec = Gem::Specification.load(File.join(ROOT, "branchproof.gemspec"))

    refute(spec.runtime_dependencies.any? { |dependency| %w[rails railties].include?(dependency.name) })
  end

  def test_rbs_and_ci_cover_the_candidate_runtime_matrix
    rbs = File.read(File.join(ROOT, "sig/branchproof.rbs"))
    workflow = File.read(File.join(ROOT, ".github/workflows/main.yml"))

    assert_includes rbs, "class Source"
    assert_includes rbs, "class Report"
    assert_includes workflow, 'ruby: ["3.3", "3.4"]'
    assert_includes workflow, "bundle exec rake"
    assert_includes workflow, "BRANCHPROOF_RAILS_INTEGRATION: \"1\""
    assert_includes workflow, "Rails 8.1"
  end
end
