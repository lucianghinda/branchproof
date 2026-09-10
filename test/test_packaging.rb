# frozen_string_literal: true

require "test_helper"
require "rubygems"

class TestPackaging < Minitest::Test
  ROOT = File.expand_path("..", __dir__).freeze

  def test_gemspec_has_runtime_identity_and_cli
    spec = Gem::Specification.load(File.join(ROOT, "branchproof.gemspec"))

    assert_equal "branchproof", spec.name
    assert_equal "0.2.0", spec.version.to_s
    assert_includes spec.files, "README.md"
    assert_includes spec.files, "CHANGELOG.md"
    assert_includes spec.files, "LICENSE.txt"
    assert_includes spec.files, "NOTICE"
    assert_includes spec.files, "lib/branchproof.rb"
    assert_includes spec.files, "exe/mcdc"
    assert_includes spec.files, "sig/branchproof.rbs"
    assert_includes spec.files, "doc/Branchproof.md"
    assert_includes spec.files, "llms.txt"
    assert_includes spec.executables, "mcdc"
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
