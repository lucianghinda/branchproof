# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "branchproof/changed_scope"

class TestChangedScope < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("branchproof-changed-scope-")
    git("init", "-q")
    git("config", "user.name", "Branchproof Test")
    git("config", "user.email", "branchproof@example.test")
    git("config", "color.ui", "always")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_maps_changed_expression_and_controlled_body_to_current_decision
    write("lib/logic.rb", "if ready?\n  work\nend\nif other?\n  keep\nend\n")
    commit_baseline
    write("lib/logic.rb", "if ready? && safe?\n  changed_work\nend\nif other?\n  keep\nend\n")
    inventory = inventory("lib/logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_equal "complete", scope[:status]
    assert_equal inventory[:decisions].first[:id], scope[:decision_ids].first
    assert_equal 1, scope[:decision_ids].length
    assert_predicate scope, :frozen?
  end

  def test_ignores_comment_only_changes
    write("logic.rb", "if ready?\n  work\nend\n")
    commit_baseline
    write("logic.rb", "if ready? # clarified\n  work\nend\n")

    scope = changed_scope

    assert_equal "empty", scope[:status]
    assert_empty scope[:decision_ids]
    assert_equal 1, scope[:files].length
  end

  def test_ignores_inline_comment_and_whitespace_only_changes
    write("logic.rb", "if ready? # old\n  work\nend\n")
    commit_baseline
    write("logic.rb", "if ready? # new\n  work\nend\n")
    assert_empty changed_scope[:decision_ids]

    write("logic.rb", "if   ready? # new\n  work\nend\n")
    assert_empty changed_scope[:decision_ids]
  end

  def test_ignores_standalone_comment_additions_and_deletions
    write("logic.rb", "if ready?\n  work\nend\n")
    commit_baseline
    write("logic.rb", "if ready?\n  # note\n  work\nend\n")
    assert_empty changed_scope[:decision_ids]

    write("logic.rb", "if ready?\n  work\nend\n")
    assert_empty changed_scope[:decision_ids]
  end

  def test_deleting_a_whole_construct_does_not_select_adjacent_decision
    write("logic.rb", "if removed?\n  old_work\nend\nif retained?\n  keep\nend\n")
    commit_baseline
    write("logic.rb", "if retained?\n  keep\nend\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_empty scope[:decision_ids]
  end

  def test_deleting_body_from_a_surviving_empty_construct_selects_its_decision
    write("logic.rb", "if ready?\n  old_work\nend\n")
    commit_baseline
    write("logic.rb", "if ready?\nend\n")

    scope = changed_scope

    assert_equal 1, scope[:decision_ids].length
  end

  def test_replacing_a_body_statement_with_a_comment_selects_surviving_controller
    write("logic.rb", "if ready?\n  call\nend\n")
    commit_baseline
    write("logic.rb", "if ready?\n  # removed call\nend\n")

    assert_equal 1, changed_scope[:decision_ids].length
  end

  def test_replacing_a_whole_construct_with_a_comment_does_not_select_neighbor
    write("logic.rb", "if removed?\n  call\nend\nif retained?\n  keep\nend\n")
    commit_baseline
    write("logic.rb", "# removed construct\nif retained?\n  keep\nend\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_empty scope[:decision_ids]
  end

  def test_maps_standalone_short_circuit_and_fallback_expressions
    write("logic.rb", "first && second\nprimary || :fallback\n")
    commit_baseline
    write("logic.rb", "first && third\nprimary || :other\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_equal 2, scope[:decision_ids].length
    assert_equal inventory[:decisions].map { |decision| decision[:id] }, scope[:decision_ids]
  end

  def test_maps_only_the_edited_subjectless_case_branch
    write("logic.rb", "case\nwhen first\n  old_work\nwhen second\n  keep\nend\n")
    commit_baseline
    write("logic.rb", "case\nwhen first\n  changed_work\nwhen second\n  keep\nend\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_equal [inventory[:decisions].first[:id]], scope[:decision_ids]
  end

  def test_maps_guarded_pattern_body_to_case_and_guard_decisions
    before = "def choose(value, enabled)\n case value\n in Integer if enabled\n  :old\n else\n  :fallback\n end\nend\n"
    after = before.sub(":old", ":new")
    write("logic.rb", before)
    commit_baseline
    write("logic.rb", after)
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)
    selected_contexts = inventory[:decisions].filter_map do |decision|
      decision[:context] if scope[:decision_ids].include?(decision[:id])
    end

    assert_includes selected_contexts, "case_in"
    assert_includes selected_contexts, "pattern_guard"
  end

  def test_subjectless_case_else_body_selects_its_case_candidates
    before = "def choose(a, b)\n case\n when a\n  :first\n when b\n  :second\n else\n  :old\n end\nend\n"
    write("logic.rb", before)
    commit_baseline
    write("logic.rb", before.sub(":old", ":new"))
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_equal inventory[:decisions].map { |decision| decision[:id] }, scope[:decision_ids]
    contexts = inventory[:decisions].map { |decision| decision[:context] }
    assert_equal %w[case_when case_when], contexts
  end

  def test_deleting_guarded_pattern_body_selects_its_guard
    before = "case value\nin Integer if enabled\n :old\nelse\n :fallback\nend\n"
    write("logic.rb", before)
    commit_baseline
    write("logic.rb", "case value\nin Integer if enabled\nelse\n :fallback\nend\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)
    guard = inventory[:decisions].find { |decision| decision[:context] == "pattern_guard" }

    assert_includes scope[:decision_ids], guard[:id]
  end

  def test_deleting_subjectless_when_body_selects_only_that_candidate
    before = "case\nwhen first\n :first\nwhen second\n :second\nend\n"
    write("logic.rb", before)
    commit_baseline
    write("logic.rb", "case\nwhen first\nwhen second\n :second\nend\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)
    selected = inventory[:decisions].select { |decision| scope[:decision_ids].include?(decision[:id]) }

    expressions = selected.map { |decision| decision[:expression] }
    assert_equal ["first"], expressions
  end

  def test_deleting_a_whole_subjectless_when_does_not_select_neighbor
    before = "case\nwhen first\n :first\nwhen second\n :second\nend\n"
    write("logic.rb", before)
    commit_baseline
    write("logic.rb", "case\nwhen first\n :first\nend\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_empty scope[:decision_ids]
  end

  def test_deleting_a_whole_subjectless_when_does_not_select_empty_neighbor_slot
    before = "case\nwhen first\nwhen second\n :second\nend\n"
    write("logic.rb", before)
    commit_baseline
    write("logic.rb", "case\nwhen first\nend\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_empty scope[:decision_ids]
  end

  def test_deleting_a_whole_when_with_blank_line_does_not_select_previous_candidate
    before = "case\nwhen first\nwhen second\n :second\n\nend\n"
    write("logic.rb", before)
    commit_baseline
    write("logic.rb", "case\nwhen first\n\nend\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_empty scope[:decision_ids]
  end

  def test_deleting_only_the_last_statement_of_a_nonempty_subjectless_when_selects_it
    before = "case\nwhen first\n :first\n :last\nend\n"
    write("logic.rb", before)
    commit_baseline
    write("logic.rb", "case\nwhen first\n :first\nend\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_equal [inventory[:decisions].first[:id]], scope[:decision_ids]
  end

  def test_maps_deleted_last_body_statement_after_prior_insertion
    before = "case\nwhen first\n :first\n :last\nend\n"
    write("logic.rb", before)
    commit_baseline
    write("logic.rb", "notice = \"café\"\n#{before.sub(" :last\n", "")}")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_equal [inventory[:decisions].first[:id]], scope[:decision_ids]
  end

  def test_maps_deleted_last_statement_after_earlier_branch_deletion
    before = "case\nwhen first\n :first\nwhen second\n :second\n :last\nend\n"
    write("logic.rb", before)
    commit_baseline
    write("logic.rb", "case\nwhen second\n :second\nend\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)
    selected = inventory[:decisions].select { |decision| scope[:decision_ids].include?(decision[:id]) }

    expressions = selected.map { |decision| decision[:expression] }
    assert_equal ["second"], expressions
  end

  def test_deleting_a_whole_guarded_in_does_not_select_neighbor_guard
    before = "case value\nin Integer if first\n :first\nin String if second\n :second\nend\n"
    write("logic.rb", before)
    commit_baseline
    write("logic.rb", "case value\nin Integer if first\n :first\nend\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)
    selected_guards = inventory[:decisions].select do |decision|
      decision[:context] == "pattern_guard" && scope[:decision_ids].include?(decision[:id])
    end

    assert_empty selected_guards
  end

  def test_deleting_subjectless_else_body_selects_all_its_candidates
    before = "case\nwhen first\n :first\nwhen second\n :second\nelse\n :fallback\nend\n"
    write("logic.rb", before)
    commit_baseline
    write("logic.rb", "case\nwhen first\n :first\nwhen second\n :second\nelse\nend\n")
    inventory = inventory("logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_equal inventory[:decisions].map { |decision| decision[:id] }, scope[:decision_ids]
  end

  def test_maps_changes_inside_multiline_string_content_as_code
    write("logic.rb", "if ready?\n  message = <<~TEXT\n    first\n    # old text\n    last\n  TEXT\nend\n")
    commit_baseline
    write("logic.rb", "if ready?\n  message = <<~TEXT\n    first\n    # new text\n    last\n  TEXT\nend\n")

    assert_equal 1, changed_scope[:decision_ids].length
  end

  def test_keeps_newline_and_semicolon_tokens_in_change_comparison
    write("logic.rb", "if ready?\n  first\n  second\nend\n")
    commit_baseline
    write("logic.rb", "if ready?\n  first second\nend\n")

    assert_equal 1, changed_scope[:decision_ids].length
  end

  def test_renamed_tracked_file_selects_all_current_decisions
    write("old.rb", "if first?\nend\nif second?\nend\n")
    commit_baseline
    File.rename(File.join(@directory, "old.rb"), File.join(@directory, "new.rb"))
    git("add", "-A", "--", "old.rb", "new.rb")
    inventory = inventory("new.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_equal "R100", scope[:files].first[:status]
    assert_equal inventory[:decisions].map { |decision| decision[:id] }, scope[:decision_ids]
  end

  def test_staged_new_ruby_file_selects_every_current_decision
    write("logic.rb", "if existing?\nend\n")
    commit_baseline
    write("new_logic.rb", "if first?\nend\nif second?\nend\n")
    git("add", "--", "new_logic.rb")
    inventory = inventory("new_logic.rb")

    scope = Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)

    assert_equal "A", scope[:files].first[:status]
    assert_equal inventory[:decisions].map { |decision| decision[:id] }, scope[:decision_ids]
  end

  def test_maps_unicode_body_edits_by_byte_safe_ranges
    write("logic.rb", "if ready?\n  message = \"café\"\nend\n")
    commit_baseline
    write("logic.rb", "if ready?\n  message = \"résumé\"\nend\n")

    assert_equal 1, changed_scope[:decision_ids].length
  end

  def test_empty_diff_is_a_valid_empty_scope
    write("logic.rb", "if ready?\nend\n")
    commit_baseline

    scope = changed_scope

    assert_equal "empty", scope[:status]
    assert_empty scope[:files]
    assert_empty scope[:decision_ids]
  end

  def test_rejects_inventory_drift
    write("logic.rb", "if ready?\nend\n")
    commit_baseline
    inventory = inventory("logic.rb")
    write("logic.rb", "if changed?\nend\n")

    error = assert_raises(ArgumentError) do
      Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)
    end

    assert_match(/stale/i, error.message)
  end

  def test_rejects_invalid_current_source_without_decisions
    write("logic.rb", "value = 1\n")
    commit_baseline
    write("logic.rb", "def broken(\n")
    inventory = inventory("logic.rb")
    assert_empty inventory[:decisions]

    error = assert_raises(ArgumentError) do
      Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory)
    end

    assert_match(/does not parse/i, error.message)
  end

  private

  def write(path, contents)
    absolute = File.join(@directory, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, contents)
  end

  def commit_baseline
    git("add", ".")
    git("commit", "-qm", "baseline")
  end

  def inventory(path)
    Branchproof::Source.new(root: @directory, limits: Branchproof::Limits.default).inventory(paths: [path])
  end

  def changed_scope
    Branchproof::ChangedScope.new(root: @directory, ref: "HEAD").call(inventory: inventory("logic.rb"))
  end

  def git(*arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: @directory)
    raise "git #{arguments.join(" ")} failed: #{output}" unless status.success?

    output
  end
end
