# Changed-decision coverage implementation plan

> Use `superpowers-ruby:subagent-driven-development` with Luna implementers and
> separate spec then quality reviewers. The user authorized implementation,
> a new branch and a new PR; continue through verification and publication.

**Goal:** Show missing coverage in current decisions affected by tracked Git
changes, while running the normal selected suite and preserving whole-run gates.

**Base:** `32a50b8`. Branch: `codex/changed-decisions`. Ruby 4.0.1, Prism and
Ruby standard library; no new dependencies.

## Contract and boundaries

`branchproof analyze --changed-since REF` resolves REF to a commit and compares
that commit with the current tracked working tree, including staged and unstaged
changes. This is a direct commit-to-working-tree comparison, not merge-base
inference. Untracked files are excluded and the report says so. Missing Git,
invalid refs, unresolved merge entries, source drift during scope capture, and
unusable scope parsing produce actionable usage errors (exit 2).

Collect names/status with NUL-delimited Git output, execute argument arrays,
disable external diff/textconv, and validate revisions with `--end-of-options`.
Support spaces, unusual names, SHA-1/SHA-256 commit IDs, nested project roots,
staged additions, deletions, renames and binary/nonselected files. Renamed and
new tracked source files conservatively select every current inventoried
decision in their destination. Deleted files have no current obligations and
are listed separately. Copy/mode changes are disclosed without inventing code
edits. Preserve captured project-relative path identity; exclude Git changes
outside the selected source inventory from decision denominators.

Map current hunk code tokens to current decision expressions and their controlled
bodies in a separate opt-in Prism pass over changed files. Do not alter source
inventory fields, IDs, instrumentation or default parsing. Nested body edits
may affect all enclosing controllers. Compare normalized old/current hunk token
sequences, ignoring comment/trivia while retaining literal contents. Equal
semantic sequences select nothing, including inline-comment or spacing-only
edits beside unchanged Ruby code. Deleted body tokens use old AST ownership,
translated through hunk line and byte offsets to surviving current controllers.
Removed constructs have no surviving decision and must not select an adjacent
unrelated decision, including empty bodies separated by blank lines. Capture
deletion information even when no current decision survives.

Scope capture checks inventory digests against mapping bytes and rechecks
relevant diff/status/content after mapping, using the fixed resolved commit.
Reject observed drift or newly unresolved merges. This is checked capture,
not a filesystem lock or an atomic Git/worktree transaction.

Capture the base ref/commit, comparison mode, excluded-untracked policy,
project-relative file changes/hunks and selected current decision IDs as an
optional `changed_scope` section. It describes report scope, not test selection.
Persist it so offline rendering needs neither Git nor a checkout. Opted-in
reports use schema 1.5; ordinary reports remain schema 1.4. The reader accepts
1.0–1.5; existing schemas retain their exact validations. A 1.5 document requires
valid changed scope and whole-run coverage policy. Reject unknown/duplicate IDs,
unsafe paths, malformed hunk counts/commit IDs/statuses and internally
inconsistent summaries. Offline validation does not authenticate the historical
Git diff: captured scope is report context, not a cross-revision proof claim.

All full inventory, observations, analysis, minima, metrics, completeness,
coverage policy and exit behavior remain whole-run. Changed coverage aggregates
the existing per-decision analysis using the same arithmetic as the analyzer.
Expose separate decision, condition, condition/decision, MC/DC, decision-table
and alternative counts. Empty/unsupported-only/unavailable denominators remain
unavailable; never display them as 100%. Failed/incomplete runs have unavailable
scope coverage. No changed-only thresholds are implemented in this slice.

Terminal/GitHub detail and ranking show selected changed decisions, intersected
with `--focus`, then capped by `--top`. These display options never affect scope
denominators. JSON retains the complete report and scope metadata; the existing
rejection of JSON `--focus`/`--top` remains. Offline reports retain captured scope.
Saved-report comparison continues comparing whole-run evidence and records
changed scope as display context; differing scope metadata cannot silently
become a changed-coverage comparison or cross-revision proof match.

## Cleanup plan for shared aggregation

If needed, extract `Analyzer#aggregate_coverage`, decision-table totals and
alternative totals into one small `CoverageSummary` utility used by Analyzer
and changed-scope reporting. Existing analyzer/decision-table regressions lock
the arithmetic before extraction; add an explicit whole-run/subset aggregation
test. Preserve all existing keys, percentages, unsupported handling and order.
Do not restructure the analyzer or introduce a second coverage engine.

## Task 1 — Git changes and current decision membership

Ownership: new `lib/branchproof/git_changes.rb`, `changed_scope.rb`,
`changed_decision_map.rb` as needed; new focused tests for these classes.
No CLI/report/source/instrumenter edits.

Public boundary:

```ruby
scope = Branchproof::ChangedScope.new(root: project_root, ref: "HEAD")
                                .call(inventory: full_inventory)
assert_equal expected_ids, scope.fetch(:decision_ids)
assert_equal "tracked_worktree", scope.fetch(:comparison)
assert_equal "excluded", scope.fetch(:untracked)
```

- [x] Write tests in real temporary Git repositories. Assert expression/body,
      nested and multiline edits select expected current IDs; comments do not.
      Test insertion/deletion anchors, removed entire constructs beside surviving
      ones, empty bodies, non-ASCII bytes, guards/case/loops/fallbacks, renamed
      paths, staged additions, deleted/nonselected files and subdirectory roots.
- [x] Run new tests and record expected failures before implementation.
- [x] Implement the bounded collector/mapper, preserving inventory immutability
      and source identity. Assert source drift, invalid refs, absent Git/nonrepo,
      option-shaped refs and unresolved merges fail with actionable errors.
- [x] Run focused tests and lint; obtain independent Luna spec then quality
      approval. Parent owns Lore commits.

Task 1 evidence: 6 Git collector tests and 30 changed-scope tests pass; all five
files pass RuboCop. Independent Luna spec and quality reviews approved. Tests
lock whole-branch adjacency, surviving empty/nonempty body deletions, pattern
guards, subjectless case fallback, comment/literal handling and preceding hunk
offset shifts. Removed the broad empty-body anchor fallback after its blank-line
false positive was reproduced; deleted bodies use translated old AST ownership.

## Task 2 — Informational scope counts, views and saved schema

Execute this task in two sequential Luna implementation slices, each with
spec then quality review: (2a) shared counts and saved/comparison contracts;
(2b) live Report integration, display selection and every renderer. This keeps
the schema and arithmetic review bounded before rendering work begins.

Ownership: shared aggregate helper/Analyzer extraction if needed;
new changed-coverage helper; Report, ReportSelection, Summary/Focused/GitHub
views, SavedReport and Comparison plus their focused tests. No CLI or docs/sig
edits yet. Task 1's scope shape is the input contract.

Public report boundary:

```ruby
report = Branchproof::Report.new(**whole_run_inputs, changed_scope: scope)
json = render_json(report)
assert_equal "1.5", json.fetch("schema_version")
assert_equal normal_json.fetch("analysis"), json.fetch("analysis")
assert_equal normal_json.fetch("coverage_policy"), json.fetch("coverage_policy")
assert_equal normal_report.exit_code, report.exit_code
```

- [x] Add failing subset/count/view/offline/schema tests, including empty,
      unsupported-only, failed/incomplete and uncalculated decision tables.
- [x] Implement shared aggregation and scope validation; retain normal 1.4 JSON.
      Changed detail filtering must work in every existing view and GitHub
      annotations/step summary. Include base, deleted-file and untracked notices.
- [x] Test --focus intersection/top cap without denominator or gate changes;
      full JSON retains all records. Validate membership and recompute counts
      from captured analysis when reading a saved report; reject tampering.
- [x] Run focused analyzer/report/saved/comparison tests and lint. Obtain Luna
      spec then quality approval before CLI integration.

Task 2a evidence: independent Luna spec and quality reviews approved shared
aggregation, changed counts and saved/comparison contracts. CoverageSummary
(2 tests), ChangedCoverage (9), SavedReport (20), Comparison (27), Analyzer (9),
coverage ladder (13) and relevant flow/table validation tests pass. Scoped
RuboCop is clean. Schema 1.5 stores both `changed_scope` and `changed_coverage`;
invalid fractions produce unavailable scope coverage, and recomputation rejects
tampered summaries. Git's zero-padded rename/copy similarity scores are retained.

Task 2b evidence: independent Luna spec and quality reviews approved live Report
integration and scoped display selection. Changed-view tests (13 tests / 293
assertions), existing report/focused/summary/GitHub and comparison tests pass;
scoped RuboCop and diff checks are clean. Regressions cover disjoint focus in
every renderer, unavailable criteria, full JSON identity, captured offline scope
and control characters in metadata and selected source paths. Ordinary output
is preserved. A conservative no-gap notice can be suppressed in a focused
criterion view when another criterion is unavailable; individual criterion
counts still show their own availability.

## Task 3 — CLI, public contracts and acceptance

Ownership: CLI, core autoloads, RBS, README and both changelogs; new subprocess
acceptance tests. Integrate the already-reviewed scope/report APIs.

- [ ] Add CLI failing tests for --changed-since, missing/ref errors, offline
      flag rejection, preserved full-suite execution (including an unchanged
      test that fails), whole-run gate failure outside changed scope, JSON
      metadata and saved offline rendering after the checkout is removed.
- [ ] Parse/resolve scope after full inventory and before the worker; pass it
      into Report without altering source paths, selected tests or payload.
      Document direct base comparison, tracked scope, rename policy, unchanged
      thresholds and schema 1.5 reader requirements. Add signatures/autoloads.
- [ ] Run focused acceptance, packaging and lint. Obtain Luna spec then quality
      approval, then a final independent review of the integrated diff.

## Final verification and delivery

- [x] Clean merged-main baseline `bundle exec rake`: 1,703 tests / 241,851
      assertions, zero failures/errors, 13 optional skips; 187 lint files clean.
- [ ] Final `bundle exec rake`, applicable RBS validation, packaging, Ruby syntax
      and `git diff --check`; existing CI framework/Rails lanes run on the PR.
- [ ] Update this plan with actual results/limitations. Commit in Lore format,
      push the branch and open a new PR. Preserve the feature worktree and
      remove temporary Ruby scripts; do not merge the PR.

All Ruby commands use Ruby 4.0.1, activated through the local version manager.
Use a writable temporary directory for the RuboCop cache. Utility scripts use
Ruby standard library in a temporary directory. No timing-based tests or
performance claims are required for this reporting feature.
