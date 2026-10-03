# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "branchproof/git_changes"

class TestGitChanges < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("branchproof-git-changes-")
    git("init", "-q")
    git("config", "user.name", "Branchproof Test")
    git("config", "user.email", "branchproof@example.test")
    git("config", "color.ui", "always")
    File.write(File.join(@directory, "decision.rb"), "if ready?\nend\n")
    git("add", "decision.rb")
    git("commit", "-qm", "baseline")
    @base = git("rev-parse", "HEAD").strip
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_collects_tracked_staged_and_unstaged_changes_but_excludes_untracked
    File.write(File.join(@directory, "decision.rb"), "if ready? && safe?\nend\n")
    git("add", "decision.rb")
    File.write(File.join(@directory, "decision.rb"), "if ready? && safe? && valid?\nend\n")
    File.write(File.join(@directory, "loose.rb"), "if ignored?\nend\n")

    changes = Branchproof::GitChanges.new(root: @directory, ref: @base).call

    assert_equal @base, changes[:base_commit]
    assert_equal "complete", changes[:status]
    assert_equal [{ status: "M", path: "decision.rb", hunks: [{ old_start: 1, old_count: 1, new_start: 1, new_count: 1 }] }],
                 changes[:files]
    assert_predicate changes, :frozen?
  end

  def test_rejects_option_like_and_unresolvable_refs_with_actionable_errors
    error = assert_raises(ArgumentError) do
      Branchproof::GitChanges.new(root: @directory, ref: "--help").call
    end

    assert_match(/commit|reference/i, error.message)

    missing = assert_raises(ArgumentError) do
      Branchproof::GitChanges.new(root: @directory, ref: "missing-branchproof-ref").call
    end
    assert_match(/invalid|unresolved/i, missing.message)
  end

  def test_rejects_non_repository_roots
    directory = Dir.mktmpdir("branchproof-not-git-")
    error = assert_raises(ArgumentError) do
      Branchproof::GitChanges.new(root: directory, ref: @base).call
    end
    assert_match(/git repository/i, error.message)
  ensure
    FileUtils.remove_entry(directory) if directory
  end

  def test_keeps_renames_deletions_staged_additions_and_unusual_paths
    File.write(File.join(@directory, "rename source.rb"), "if old?\nend\n")
    git("add", "--", "rename source.rb")
    git("commit", "-qm", "add rename source")
    base = git("rev-parse", "HEAD").strip

    File.rename(File.join(@directory, "rename source.rb"), File.join(@directory, "rename target.rb"))
    git("add", "-A", "--", "rename source.rb", "rename target.rb")
    FileUtils.rm(File.join(@directory, "decision.rb"))
    File.write(File.join(@directory, "-- odd\nname.rb"), "if staged?\nend\n")
    git("add", "--", "-- odd\nname.rb")
    File.write(File.join(@directory, "untracked.rb"), "if ignored?\nend\n")

    files = Branchproof::GitChanges.new(root: @directory, ref: base).call[:files]

    assert_equal %w[A D R100], files.map { |file| file[:status] }.sort
    assert_includes files.map { |file| file[:path] }, "-- odd\nname.rb"
    assert_includes files.map { |file| file[:path] }, "rename target.rb"
    refute_includes files.map { |file| file[:path] }, "untracked.rb"
  end

  def test_scopes_paths_to_a_nested_project
    FileUtils.mkdir_p(File.join(@directory, "packages", "one"))
    File.write(File.join(@directory, "packages", "one", "inside.rb"), "if inside?\nend\n")
    File.write(File.join(@directory, "outside.rb"), "if outside?\nend\n")
    git("add", ".")
    git("commit", "-qm", "baseline")
    base = git("rev-parse", "HEAD").strip
    File.write(File.join(@directory, "packages", "one", "inside.rb"), "if inside? && changed?\nend\n")
    File.write(File.join(@directory, "outside.rb"), "if outside? && changed?\nend\n")

    files = Branchproof::GitChanges.new(root: File.join(@directory, "packages", "one"), ref: base).call[:files]

    assert_equal(["inside.rb"], files.map { |file| file[:path] })
  end

  def test_rejects_unresolved_merge_entries
    main = git("symbolic-ref", "--short", "HEAD").strip
    git("checkout", "-qb", "branchproof-side")
    File.write(File.join(@directory, "decision.rb"), "if side?\nend\n")
    git("commit", "-qam", "side change")
    git("checkout", "-q", main)
    File.write(File.join(@directory, "decision.rb"), "if main?\nend\n")
    git("commit", "-qam", "main change")
    git("checkout", "-q", "branchproof-side")
    output, status = Open3.capture2e("git", "merge", main, chdir: @directory)
    refute status.success?, output

    error = assert_raises(ArgumentError) do
      Branchproof::GitChanges.new(root: @directory, ref: "HEAD").call
    end
    assert_match(/unresolved merge/i, error.message)
  end

  private

  def git(*arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: @directory)
    raise "git #{arguments.join(" ")} failed: #{output}" unless status.success?

    output
  end
end
