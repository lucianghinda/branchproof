# frozen_string_literal: true

require "test_helper"
require "branchproof/analyzer"
require "branchproof/report"
require "branchproof/saved_report"
require "fileutils"
require "stringio"
require "tmpdir"

class TestChangedViews < Minitest::Test
  SOURCE = <<~RUBY
    def allowed?(premium, admin, owner)
      premium && (admin || owner)
    end
  RUBY

  WINDOW_SOURCE = <<~RUBY
    def window?(age)
      age && false
    end
  RUBY

  ODD_SOURCE = <<~RUBY
    def odd_path?(flag, other)
      flag || other
    end
  RUBY

  def setup
    @root = Dir.mktmpdir("branchproof-changed-view-")
    FileUtils.mkdir_p(File.join(@root, "lib"))
    File.binwrite(File.join(@root, "lib", "policy.rb"), SOURCE)
    File.binwrite(File.join(@root, "lib", "window.rb"), WINDOW_SOURCE)
    File.binwrite(File.join(@root, "lib", "odd\npath.rb"), ODD_SOURCE)
    @inventory = Branchproof::Source.new(root: @root, limits: Branchproof::Limits.default)
                                    .inventory(paths: ["lib/policy.rb", "lib/window.rb", "lib/odd\npath.rb"])
    @allowed = @inventory.fetch(:decisions).find { |decision| decision.fetch(:expression).include?("premium") }
    @window = @inventory.fetch(:decisions).find { |decision| decision.fetch(:expression).include?("age") }
    @odd = @inventory.fetch(:decisions).find { |decision| decision.fetch(:expression).include?("flag") }
    @evidence = evidence_for([@allowed, @window, @odd])
    @analysis = Branchproof::Analyzer.new(inventory: @inventory, evidence: @evidence,
                                          limits: Branchproof::Limits.default).call
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def changed_scope(ids: [@allowed.fetch(:id)])
    { version: "1.0", requested_ref: "main", base_commit: "a" * 40, comparison: "tracked_worktree",
      untracked: "excluded", status: ids.empty? ? "empty" : "complete", files: [
        { status: "M", path: "lib/policy.rb", hunks: [{ old_start: 1, old_count: 4, new_start: 1, new_count: 4 }] },
        { status: "M", path: "lib/window.rb", hunks: [{ old_start: 1, old_count: 3, new_start: 1, new_count: 3 }] },
        { status: "M", path: "lib/odd\npath.rb", hunks: [{ old_start: 1, old_count: 3, new_start: 1, new_count: 3 }] },
        { status: "D", path: "lib/removed.rb", hunks: [] }
      ], decision_ids: ids }
  end

  def report(view: :decisions, scope: changed_scope, **)
    Branchproof::Report.new(inventory: @inventory, evidence: @evidence, analysis: @analysis, minima: [],
                            baseline: { status: "PASSED", finalized: true, executed_tests: 1 }, diagnostics: [],
                            view: view, changed_scope: scope, **)
  end

  def render(report, format: :terminal)
    output = StringIO.new
    report.write(io: output, format: format)
    output.string
  end

  def test_scoped_json_adds_versioned_scope_without_changing_whole_run_evidence
    full = report(scope: nil)
    scoped = report

    full_json = JSON.parse(render(full, format: :json))
    scoped_json = JSON.parse(render(scoped, format: :json))

    assert_equal "1.4", full_json.fetch("schema_version")
    assert_equal "1.5", scoped_json.fetch("schema_version")
    %w[source_inventory observations analysis minima metrics completeness baseline coverage_policy run_metadata].each do |key|
      assert_equal full_json[key], scoped_json[key], "#{key} must remain whole-run evidence"
    end
    assert_equal JSON.parse(JSON.generate(changed_scope)), scoped_json.fetch("changed_scope")
    assert_equal "available", scoped_json.dig("changed_coverage", "status")
    assert_equal full.exit_code, scoped.exit_code
    assert_equal scoped_json, Branchproof::SavedReport.new(scoped_json).validate!
  end

  def test_all_terminal_views_and_github_output_identify_scope_and_changed_coverage
    %i[decisions conditions tests decision_tables summary].each do |view|
      output = render(report(view: view))
      assert_includes output, "Changed scope: main (resolved"
      assert_includes output, "tracked worktree"
      assert_includes output, "untracked files excluded"
      assert_includes output, "Deleted files"
      assert_includes output, "Changed coverage (informational)"
      assert_includes output, "Decision:"
      assert_includes output, "MC/DC:"
    end

    github = report
    annotations = render(github, format: :github)
    assert_includes annotations, "Changed scope: main (resolved"
    refute_includes annotations, "age && false"
    assert_includes github.step_summary, "Changed coverage (informational)"
  end

  def test_changed_scope_filters_every_view_without_changing_global_ladder_or_exit
    whole = report(scope: nil)
    %i[decisions conditions tests decision_tables summary].each do |view|
      scoped = report(view: view)
      output = render(scoped)
      refute_includes output, "age && false", "#{view} must hide out-of-scope decisions"
      assert_equal whole.exit_code, scoped.exit_code
    end
  end

  def test_focus_outside_changed_scope_is_reported_as_no_matching_changed_decisions
    output = render(report(view: :summary, focus: "lib/window.rb"))
    table_output = render(report(view: :decision_tables, focus: "lib/window.rb", missing_only: true))

    assert_includes output, "Focus: no matching changed decisions for lib/window.rb"
    refute_includes output, "No changed-scope gaps found"
    assert_includes table_output, "Focus: no matching changed decisions for lib/window.rb"
    refute_includes table_output, "No missing decision-table rules"
  end

  def test_decisions_missing_summary_reports_empty_scope_focus_intersection
    output = render(report(view: :decisions, missing_only: true, focus: "lib/window.rb"))
    focused = render(report(view: :conditions, focus: "lib/window.rb"))
    github = report(focus: "lib/window.rb")

    assert_includes output, "Focus: no matching changed decisions for lib/window.rb"
    assert_includes output, "Changed-scope missing coverage unavailable"
    refute_includes output, "No missing conditions, alternatives, or decision-table rules"
    assert_includes focused, "Focus: no matching changed decisions for lib/window.rb"
    assert_includes github.step_summary, "no matching changed decisions for"
    assert_includes render(github, format: :github), "no matching changed decisions for"
    refute_includes github.step_summary, "No changed-scope gaps found"
    refute_includes render(github, format: :github), "No changed-scope gaps found"
  end

  def test_unusual_scope_metadata_is_safe_in_terminal_and_github_markdown
    scope = changed_scope.merge(requested_ref: "branch\n::warning::", files: [
                                  { status: "D", path: "lib/odd\n|`name.rb", hunks: [] }
                                ])
    report = report(view: :summary, scope: scope)
    terminal = render(report)
    summary = report.step_summary

    assert_includes terminal, "branch\\u{A}::warning::"
    assert_includes terminal, "lib/odd\\u{A}|`name.rb"
    refute_includes summary, "- Changed scope: branch"
    assert_includes summary, "- `Changed scope: branch\\u{A}::warning::"
    assert_includes summary, "lib/odd\\u{A}\\|`name.rb"
  end

  def test_unscoped_github_annotations_do_not_add_a_focus_notice
    annotations = render(report(scope: nil, focus: "lib/policy.rb"), format: :github)

    refute_includes annotations, "Focus:"
  end

  def test_scoped_terminal_views_escape_newline_source_paths_and_focus_labels
    scope = changed_scope(ids: [@odd.fetch(:id)])
    focus = "lib/odd\npath.rb"

    %i[decisions conditions tests decision_tables summary].each do |view|
      output = render(report(view: view, scope: scope, focus: focus))

      assert_includes output, "lib/odd\\u{A}path.rb"
      assert_includes output, "Focus: lib/odd\\u{A}path.rb"
      refute_includes output, "lib/odd\npath.rb"
    end

    unscoped = render(report(scope: nil))
    assert_includes unscoped, "lib/odd\npath.rb"
  end

  def test_test_view_prunes_observations_for_unchanged_decisions_on_shared_test
    output = render(report(view: :tests))

    assert_includes output, "premium"
    refute_includes output, "age (lib/policy.rb:", "the same test's unchanged decision observation must not leak"
  end

  def test_focus_intersects_changed_scope_and_top_only_limits_display
    ids = [@allowed.fetch(:id), @window.fetch(:id)]
    scope = changed_scope(ids: ids)
    minimum = { mcdc: 100 }
    scoped = report(view: :summary, scope: scope, focus: "lib/policy.rb", top: 1, minimum: minimum)
    whole = report(scope: nil, minimum: minimum)
    output = render(scoped)
    unfiltered_json = JSON.parse(render(report(view: :summary, scope: scope, minimum: minimum), format: :json))

    assert_includes output, "Focus: lib/policy.rb"
    assert_equal 2, unfiltered_json.dig("changed_coverage", "selected_decisions")
    assert_equal "available", unfiltered_json.dig("changed_coverage", "status")
    assert_equal 1, whole.exit_code
    assert_equal whole.exit_code, scoped.exit_code
    assert_raises(ArgumentError) { render(scoped, format: :json) }
  end

  def test_empty_changed_scope_does_not_claim_no_missing_coverage
    scope = changed_scope(ids: [])
    output = render(report(view: :summary, scope: scope, missing_only: true))

    assert_includes output, "Changed coverage unavailable"
    refute_includes output, "No missing coverage"
    refute_includes output, "No missing conditions"
  end

  def test_uncalculated_changed_decision_table_stays_visible_as_unavailable
    analysis = Marshal.load(Marshal.dump(@analysis))
    row = analysis.fetch(:decisions).find { |item| item.fetch(:decision_id) == @window.fetch(:id) }
    row[:decision_table] = { status: "not_calculated", reason: "decision_table_unavailable" }
    scoped = Branchproof::Report.new(inventory: @inventory, evidence: @evidence, analysis: analysis, minima: [],
                                     baseline: { status: "PASSED", finalized: true }, diagnostics: [],
                                     changed_scope: changed_scope(ids: [@window.fetch(:id)]), view: :summary)
    json = JSON.parse(render(scoped, format: :json))
    output = render(scoped)

    assert_equal "available", json.dig("changed_coverage", "status")
    assert_equal "unavailable", json.dig("changed_coverage", "coverage", "decision_table", "status")
    assert_match(/Decision table: unavailable \(decision table analysis was not calculated\)/, output)
    refute_includes output, "Decision table: 100%"
    refute_includes output, "No changed-scope gaps found"
  end

  def test_offline_scoped_document_round_trips_without_git_or_source_access
    document = JSON.parse(render(report, format: :json))
    rendered = Branchproof::Report.from_document(document: document, view: :summary)

    assert_includes render(rendered), "Changed scope: main (resolved"
    assert_equal document, JSON.parse(render(rendered, format: :json))
  end

  private

  def evidence_for(decisions)
    evidence = Branchproof::Evidence.new(inventory: @inventory, limits: Branchproof::Limits.default, run_id: "run")
    evidence.register_test(test: { id: "shared-test", adapter: "minitest", name: "PolicyTest#test_all",
                                   class_name: "PolicyTest", method_name: "test_all", phase_counts: {} })
    decisions.each do |decision|
      samples = if decision.equal?(@allowed)
                  [[false, nil, nil, false], [true, true, nil, true], [true, false, false, false]]
                elsif decision.equal?(@odd)
                  [[false, false, false], [true, nil, true]]
                else
                  [[false, nil, false], [true, false, false]]
                end
      samples.each do |sample|
        values = sample[0...-1]
        observations = values.each_with_index.filter_map { |value, index| [index, value] unless value.nil? }
        result = evidence.record(execution: { run_id: "run", decision_id: decision.fetch(:id),
                                              test_id: "shared-test", phase: "body", observations: observations,
                                              outcome: sample.last, status: "completed" })
        assert_equal "recorded", result.fetch(:status), result.fetch(:reason)
      end
    end
    evidence.snapshot
  end
end
