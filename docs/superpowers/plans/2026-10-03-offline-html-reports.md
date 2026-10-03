# Offline HTML Reports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-ruby:subagent-driven-development. Steps use checkbox syntax for tracking.

**Goal:** Render saved evidence as an accessible, self-contained HTML report.

**Architecture:** HtmlReport adapts CoverageIndex and SummaryRanking using Report
as coordinator. CLI enables the format only for offline report; calculations,
saved schemas and gates stay unchanged.

**Tech Stack:** Ruby 4 standard library, static HTML/CSS, Minitest, RBS.

## Task 1: Renderer and report integration

Files: create `lib/branchproof/html_report.rb`, `test/test_html_report.rb`;
modify `lib/branchproof/report.rb`, `sig/branchproof.rbs` as applicable.

- [x] Add failing renderer tests using existing SummaryDocument fixture for
  ordering, missing cases, conditions/alternatives, excluded rules, attribution,
  unavailable/incomplete states, focus/top/missing-only and hostile text.
  Exercise `Report.from_document(document: document).write(io: output, format: :html)`.
- [x] Run `bundle exec ruby -Itest test/test_html_report.rb` and record expected
  unsupported-format failure before implementation.
- [x] Implement `HtmlReport.new(document:, level:, coordinator:, missing_only:,
  selection:).render`; require it from Report and add :html write dispatch. Use
  generated internal anchors and one escaping function for all snapshot text.
  Reuse `SummaryReport.case_lines`, coordinator coverage/policy lines, and index
  decision-table rows including excluded evidence. Respect the design's selectors
  and levels; render inventory without analysis as unavailable evidence.
- [x] Run new tests and relevant existing report tests; run RuboCop on touched Ruby.
- [x] Independent Luna spec review, then quality review; resolve findings.
- [x] Parent commits reviewed change with Lore decision trailers.

## Task 2: Offline CLI, acceptance, user documentation

Files: modify `lib/branchproof/cli.rb`, `test/test_saved_report_acceptance.rb`
(or focused new HTML acceptance test), `test/test_cli.rb`, `README.md`,
`CHANGELOG.md`, signatures if required.

- [x] Add failing acceptance tests for HTML stdout/file output after deleting the
  source checkout; reject explicit view, live analyze HTML and compare HTML;
  preserve input/output protection and global minimum exit status with changed scope.
- [x] Run targeted tests to observe option-rejection failures.
- [x] Extend offline report formats with html and help text; allow missing-only
  for HTML level 2/3; keep existing terminal/JSON/GitHub option semantics intact.
- [x] Document command, portability, selectors/levels, global gates, unavailable
  evidence, offline-only boundary, and CI artifact use. Add unreleased changelog.
- [x] Run targeted CLI and saved-report tests and RuboCop.
- [x] Independent Luna spec review, then quality review; resolve findings.
- [x] Parent commits reviewed change with Lore decision trailers.

## Task 3: Integrated verification and delivery

- [x] Generate a representative report with multiple files, gaps, covered and
  excluded cases, attribution, long/hostile text, and changed-scope metadata.
- [x] Inspect actual report in browser at desktop/mobile widths and with keyboard;
  verify internal navigation, no remote assets/scripts, and source independence.
  Record visual verdict against written design before any visual revision.
- [x] Run `bundle exec rake` (tests and RuboCop), signature validation, gem packaging
  smoke test, and `bundle exec rake docs`; inspect generated documentation changes.
- [x] Fresh Luna integrated review, resolve findings, rerun affected verification.
Delivery follows local verification: commit the record, push the feature branch,
create the PR with concrete behavior and test evidence, then check CI and fix failures.
Publication status is recorded in the PR and final handoff.

All Ruby commands use Ruby 4.0.1 via PATH. Use temporary Ruby standard-library
scripts for fixture generation. No dependency or version changes are planned.
