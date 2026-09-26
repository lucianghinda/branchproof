## [Unreleased]

## [0.11.0] - 2026-09-25

- Add validated coverage policies for Decision, Condition, Condition/Decision,
  MC/DC, and Decision Table criteria. Repeatable `--minimum criterion=threshold`
  options override matching project or saved-report policy entries, compare
  exact counts, and distinguish failed gates from unavailable or incomplete
  evidence in exit status and JSON.
- Persist policy decisions in live schema `1.4` reports while keeping saved
  schemas `1.0` through `1.3` readable; offline policy overrides do not load
  project configuration or mutate snapshots.
- Add terminal-only `--focus PATH[:LINE]` and `--top N` selection for analyze
  and report views. Selection uses captured source spans and deterministic source
  order while leaving global summaries, gates, diagnostics, and exit status
  unchanged.
- Document a GitHub Actions artifact workflow that creates the output directory
  and uploads reports after gate failures.
- Preserve setup, body, and teardown phase totals when independent evidence runs
  are merged, keeping phase attribution complete in combined snapshots.
- Add declarative `.branchproof.json` project configuration with CLI precedence,
  source exclusions, and comparison metadata for repeatable coverage runs.
- Add a pipeline benchmark harness that exposes timing dimensions for future
  measurements of coverage feedback costs.

## [0.10.0] - 2026-09-21

- Add the first-release RSpec execution path for plain Ruby and Rails projects.
  It supports RSpec 3.13, including Rails 8.1 with rspec-rails 8.x on CRuby 3.4.
  Integration is verified against rspec-rails 8.0.4 and native RSpec behavior.
- Add `--framework auto|minitest|rspec`, native RSpec discovery that respects
  exclusions and custom patterns, full-description labels, and status mapping for pending,
  skipped, fixed pending, and failed examples.
- Keep Rails helper ownership with the application after Branchproof's loader;
  transaction behavior, in-process specs, and context/suite/unattributed
  evidence are recorded explicitly.
- Allow focused pure-Ruby specs inside Rails projects without requiring Rails boot.
- Match RSpec examples across saved reports only when spec and declaration
  revisions agree, preventing false matches after examples are inserted or reordered.
- Stream test progress to stderr, show quoted RSpec rerun commands, and explain
  unmatched test globs, empty suites, and filters selecting no examples.
- Document repeated ordinary and shared-example benchmarks with allocations
  and peak process memory; end-to-end overhead remains substantial.

## [0.9.0] - 2026-09-18

- Measure contextual predicates, guarded pattern selection, dynamic case splat
  groups, required pattern matching, and safe-navigation compound assignment.
- Add coverage for rescue paths, optional argument binding, standalone
  predicates, value alternatives, iteration, and source-visible callbacks.
- Preserve Boolean criteria for Boolean decisions and report other choices as
  alternative coverage, including their source locations and supporting tests.
- Exercise 144 Ruby construct fixtures and 406 native cases across source inventory, native behavior,
  runtime evidence, analysis, reports, saved reports, and CLI integration.
- Preserve nonlocal control transfers on the right side of logical expressions.
- Harden default-argument, exception, and iteration instrumentation around
  implicit parameters, nonlocal transfers, nested frames, and deferred callbacks.
- Remove unreachable integer bitwise alternatives and keep their exclusions out
  of coverage denominators.
- Cache repeated value evidence while preserving vector counts, test/phase
  attribution, and saved-report coverage semantics.

## [0.8.0] - 2026-09-17

- Derive a reduced decision table for every supported Boolean decision from its
  `AND`/`OR`/`NOT`/atom structure, preserving Ruby short-circuit semantics with
  an explicit `dont_care` value instead of exhaustive Cartesian expansion.
- Give every rule a stable identity derived from the decision, its normalized
  condition vector, the expected outcome, and the table schema version, so
  saved reports compare across runs, test order, and Minitest seeds.
- Overlay the existing run's observations onto the rules, attribute covered
  rules to their Minitest tests, and describe uncovered rules as condition-value
  requirements. No additional test execution is performed.
- Report Decision Table Coverage as its own criterion in the coverage ladder,
  per decision and in aggregate, independently from MC/DC in both directions.
- Add conservative reachability: `observed`, `unknown`, and
  `statically_impossible` with stable reason codes. Constraint analysis version 2
  requires safe source constraints before excluding rules, keeping arbitrary
  comparison receivers, mutation, and unordered numeric cases unknown.
- Exclude statically impossible rules from coverage denominators while keeping
  them visible, and let runtime evidence withdraw an impossibility claim with a
  `constraint_model_conflict` diagnostic.
- Add `--view decision-tables`, which honours `--missing-only` and never lists
  an impossible rule as a missing obligation.
- Bound table derivation with the new `max_conditions_for_decision_table` and
  `decision_table_rules_per_decision` limits.
- Persist the table, rule identities, coverage, attribution, and reachability in
  schema `1.3` reports, and distinguish rule-coverage changes from reachability
  changes in offline comparison.
- Enforce exact rule-limit boundaries and index runtime rule matching rather
  than scanning all observations per rule.
- Add `--no-reachability` to keep all generated rules as coverage obligations.
- Align the JSON regression flag with decision-table CLI failures, report
  analysis-version changes, and validate saved rule identities and evidence.
- Keep uncalculated decision locations and reasons in missing-only reports;
  label `unless` and `until` outcomes as predicate values.

## [0.7.0] - 2026-09-10

- Discover Boolean loop predicates, subjectless case candidates, standalone
  short-circuit expressions, and pattern predicates through Prism.
- Analyze unary NOT and keyword `and`/`or` with Ruby's parsed precedence.
- Attribute selected paths for ordinary case, unguarded case/in, safe navigation,
  and conditional assignments without adding them to MC/DC denominators.
- Expose decision kinds, contexts, alternative evidence, and explicit unsupported
  constructs in schema 1.2 reports while retaining older saved-report support.

## [0.6.0] - 2026-09-10

- Report Decision, Condition, and Condition/Decision Coverage alongside
  existing MC/DC evidence from one test execution.
- Show explicit coverage counts, supporting tests, and missing Boolean
  observations in decision, condition, and test views and JSON reports.
- Calculate the same coverage criteria at every reporting level and retain
  analysis in level-1 snapshots for offline inspection at higher detail.
  Continue to support legacy snapshots without analysis at level 1.

## [0.5.0] - 2026-09-10

- Show source filenames beside diagnostics in decision, condition, and test
  views, including reports rendered from saved JSON.
- Explain when a selected file has no supported conditions to instrument and
  include unsupported syntax reasons when its decisions cannot be instrumented.

## [0.4.0] - 2026-09-10

- Added `branchproof` as the primary CLI command while retaining `mcdc` as a
  compatibility alias.
- Added condition-focused and test-focused terminal views, including relative
  source locations, evaluated and short-circuited observations, and analyzer
  witness ownership.
- Added opt-in saved JSON reports, offline rendering, and exact-condition
  comparisons with gained/lost proof and changed-source context.
- Added `--fail-on-regression` comparison status handling and documented the
  local `.branchproof/` artifact directory and explicit baseline workflow.

## [0.3.0] - 2026-09-10

- Add `--missing-only` to focus terminal reports on unproven conditions.
- Explain missing observations with required truth values and comparison tests.
- Fix incorrect `INFEASIBLE_IN_MODEL` results caused by missing source identifiers.

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
