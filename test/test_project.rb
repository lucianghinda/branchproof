# frozen_string_literal: true

require "test_helper"
require "branchproof/project"
require "tmpdir"

class TestProject < Minitest::Test
  def test_ruby_project_has_absolute_root_and_empty_environment
    Dir.mktmpdir do |root|
      project = Branchproof::Project.new(root: root, mode: "ruby").to_h

      assert_equal "ruby", project[:kind]
      assert_equal File.expand_path(root), project[:root]
      assert_equal [File.join(root, "lib"), File.join(root, "test")], project[:load_paths]
      assert_equal({}, project[:environment])
    end
  end

  def test_auto_selects_rails_only_when_both_boot_files_exist
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      FileUtils.touch(File.join(root, "config", "application.rb"))
      FileUtils.touch(File.join(root, "config", "environment.rb"))

      project = Branchproof::Project.new(root: root, mode: "auto").to_h

      assert_equal "rails", project[:kind]
      assert_equal({ "RAILS_ENV" => "test", "RACK_ENV" => "test", "PARALLEL_WORKERS" => "1",
                     "DISABLE_BOOTSNAP" => "1", "DISABLE_SPRING" => "1" }, project[:environment])
    end
  end

  def test_explicit_rails_requires_application_and_environment
    Dir.mktmpdir do |root|
      error = assert_raises(ArgumentError) { Branchproof::Project.new(root: root, mode: "rails") }
      assert_includes error.message, "config/application.rb"
      assert_includes error.message, "config/environment.rb"
    end
  end

  def test_invalid_mode_is_rejected
    error = assert_raises(ArgumentError) { Branchproof::Project.new(root: Dir.pwd, mode: "wat") }

    assert_includes error.message, "project must be auto, ruby, or rails"
  end

  def test_auto_selects_rspec_from_spec_files_and_uses_spec_load_path
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "spec/support"))
      FileUtils.touch(File.join(root, "spec/example_spec.rb"))
      FileUtils.touch(File.join(root, "spec/support/spec_helper.rb"))

      project = Branchproof::Project.new(root: root).to_h

      assert_equal "rspec", project[:framework]
      assert_equal [File.join(root, "lib"), File.join(root, "spec")], project[:load_paths]
      assert_equal ["spec/**/*_spec.rb"], project[:test_patterns]
    end
  end

  def test_auto_rejects_projects_with_both_framework_markers
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "spec"))
      FileUtils.mkdir_p(File.join(root, "test"))
      FileUtils.touch(File.join(root, "spec/example_spec.rb"))
      FileUtils.touch(File.join(root, "test/example_test.rb"))

      error = assert_raises(ArgumentError) { Branchproof::Project.new(root: root) }
      assert_includes error.message, "both RSpec and Minitest"
      assert_equal "rspec", Branchproof::Project.new(root: root, framework: "rspec").to_h[:framework]
    end
  end

  def test_explicit_framework_overrides_ambiguous_markers_in_either_direction
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "spec"))
      FileUtils.mkdir_p(File.join(root, "test"))
      FileUtils.touch(File.join(root, "spec/example_spec.rb"))
      FileUtils.touch(File.join(root, "test/example_test.rb"))

      assert_equal "rspec", Branchproof::Project.new(root: root, framework: "rspec").to_h[:framework]
      assert_equal "minitest", Branchproof::Project.new(root: root, framework: "minitest").to_h[:framework]
    end
  end

  def test_plain_ruby_without_markers_keeps_minitest_defaults
    Dir.mktmpdir do |root|
      project = Branchproof::Project.new(root: root).to_h

      assert_equal "minitest", project[:framework]
      assert_equal ["test/**/*_test.rb", "test/**/test_*.rb"], project[:test_patterns]
      assert_equal [File.join(root, "lib"), File.join(root, "test")], project[:load_paths]
    end
  end
end
