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
end
