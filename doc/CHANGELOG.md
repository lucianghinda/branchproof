## [Unreleased]

## [0.2.0] - 2026-09-09

- Prepared the initial public-release candidate.
- Embedded evidence snapshots now report the package version used to produce them.

- Added the `mcdc analyze` command for one serial Minitest run.
- Added Levels 1–3 reports for observations, supporting sets, and MC/DC
  independence evidence in terminal and JSON formats.
- Added bounded analysis limits and explicit diagnostics for unsupported or
  incomplete evidence.
- Added automatic and explicit Ruby and Rails project selection for
  `mcdc analyze`.
- Added deterministic Minitest discovery for both `*_test.rb` and `test_*.rb`
  files.
- Added isolated Rails test boot with serial, test-environment defaults and
  Rails project metadata in reports.
- Added support documentation for plain Ruby and Rails projects, including
  the tested Rails 8.1 integration boundary.
- Added support for ordinary Ruby ternary (`condition ? left : right`)
  predicates, including existing `&&`/`||` condition trees and predicate
  outcome semantics independent of the selected branch value.
- Improved terminal reports with readable decision and condition labels,
  test names, compact collision-safe IDs, witness and constraint details, and
  named supporting-test sets while preserving the full JSON report.
- Fixed nested predicate selection so executed ternary decisions are recorded
  across all nested levels without instrumenting unchosen branches.
- Changed the project license to Apache-2.0; packaged `LICENSE.txt` and
  `NOTICE`.
- Renamed the gem and public namespace to `branchproof` and `Branchproof`;
  retained `mcdc` and `MCDC` as compatibility surfaces.

## [0.1.0] - 2026-09-09 (unpublished internal milestone)

- Initial analytical core and Minitest instrumentation milestone.
