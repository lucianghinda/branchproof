## [Unreleased]

### Fixed

- Keep worker startup diagnostics concise when warnings precede an exception,
  while retaining bounded stdout and stderr tails in JSON details.

## [0.12.1] - 2026-10-06

### Fixed

- Preserve Ruby source encoding when compiling instrumented files. UTF-8 strings without an explicit encoding comment now retain their encoding, preventing emoji comparison failures and incompatible-encoding errors in Rails helpers and views.
- Measure value-context `||` guards ending in receiverless `raise`/`fail` or a
  control-flow jump by their left predicate. Both branch choices now contribute
  coverage before the right-hand side raises or transfers control, without
  assigning impossible Boolean obligations to the terminal operand. Guard
  decision IDs change; predicate-context and generic aborted-trace behavior is
  unchanged.

## [0.12.0] - 2026-10-05

- Fix compilation of instrumented rescue bodies with early returns when Ruby
  branch coverage is enabled, preserving return values, exception handling,
  and `ensure` behavior.
- Combine compatible serial reports with `branchproof collate`, recomputing
  coverage and gates from merged observations. An optional expected-shard
  manifest distinguishes complete collections from missing or unknown inputs;
  incomplete collections cannot pass. Schema `1.7` retains shard provenance,
  while existing analyze schemas remain unchanged. Terminal, GitHub, and HTML
  output disclose collection status. No application boot or test run is needed.
- Support serial plain Ruby applications using Minitest 6 while retaining
  Minitest 5.25.5 and later. Doctor accepts the same `>= 5.25.5, < 7` range.
  Recognize Minitest 6 parallel scheduling and reject bisect/server execution
  before test bodies run. Frameworks remain application-supplied dependencies.
- Add independent changed-decision gates with `--minimum-changed`, paired with
  `analyze --changed-since` or a saved report's captured scope. Terminal, GitHub,
  and HTML show changed-policy results; JSON schema `1.6` records and validates
  them. Valid empty scopes are explicitly not applicable, and incomplete or
  unavailable evidence cannot pass a changed gate.
- Explain missing MC/DC evidence using captured expressions, an observed vector,
  and a suggested counterpart. Shared report wording distinguishes hypothetical
  candidates from observations and preserves short-circuit information.
- Add `branchproof doctor` for static setup checks of the Ruby runtime, selected
  test framework metadata, project configuration, and source/test file selection.
  The command reports terminal or JSON results without loading project code or
  running tests; it exits 2 when setup is blocked. See the README for its
  readiness limits and JSON shape.
- Make Minitest and RSpec application-supplied optional dependencies. Branchproof
  now needs only Prism at runtime; saved reports can be rendered and compared
  without either test framework installed.
- Render saved reports as self-contained offline HTML with `branchproof report
  snapshot.json --format html`. HTML preserves whole-run policy and exit status,
  supports display filters, and can be uploaded as a CI artifact without rerunning
  tests; HTML is unavailable for live analysis and comparison.
- Add `analyze --changed-since REF` for informational coverage of current
  decisions affected by tracked staged and unstaged worktree changes. Tests,
  whole-run coverage, and minimum gates retain their existing scope; captured
  changed-scope reports use JSON schema `1.5` and remain available offline.
- Speed up level-3 supporting-set minimization by avoiding repeated Set
  differences in greedy selection. Large synthetic RSpec and Minitest runs
  take 70–77% less end-to-end time on Ruby 4.0.1; selected sets, search
  budgets, report fields, and exit statuses are preserved. See the
  [performance record](https://github.com/lucianghinda/branchproof/blob/main/docs/benchmarks/supporting-set-performance-2026-10-02.md)
  for measurements and allocation/memory limits.

- Require Ruby 4.0 or newer and run core, RSpec, and Rails CI on Ruby 4.0.
- `branchproof mutate` now exits with status 2 and says that mutation testing
  is not supported yet, instead of the generic unknown-command error.
- Add RBS signatures for `Branchproof::Worker`.
- Add `--view summary` for `analyze` and `report`. It ranks source files and
  decisions with gaps: unexecuted decisions first, then the most missing
  decision-table rules, unproven MC/DC conditions, and missing alternatives.
  Each row shows its location, counts with denominators, the cases to test
  (level 2+), and the tests that already reach the decision (level 3).
  `--top`, `--focus`, and `--missing-only` apply; global summaries, gates,
  and exit status are unchanged.
- Add `--format github` for `analyze` and `report`. It prints GitHub Actions
  annotations in summary-view order, errors for failed or incomplete runs
  and unmet policy gates, and a final coverage notice. Annotation paths are
  made repository-relative with `GITHUB_WORKSPACE`. When `GITHUB_STEP_SUMMARY` is set, it
  also appends a Markdown job summary with the ladder, gates, and ranked gaps.
- Add `Branchproof::RakeTask`. `require "branchproof/rake_task"` defines a
  Rake task that runs `branchproof analyze` in a subprocess with the options
  set in the Rakefile. Unset options keep the CLI and `.branchproof.json`
  defaults, and a non-zero CLI exit status fails the Rake process with the
  same status.

- Report value-context `||` chains that end in a string, symbol, or numeric
  literal (including interpolated strings and symbols), such as
  `name.presence || entry&.title || "Item #{id}"`, as `fallback` alternatives:
  each operand is an alternative, covered when a test makes it the one that
  supplies the value. These chains are no longer Boolean `short_circuit`
  decisions, so they leave the MC/DC and decision-table denominators. Chains
  used as conditions (`if`, `unless`, `while`, `until`, ternary, and
  `case`/`when`), chains that end in `true`, `false`, or `nil`, keyword `or`,
  and chains whose operands contain `&&`, `||`, `!`, or a jump (`return`,
  `break`, `next`, `redo`, `retry`) keep Boolean treatment.
- Decision IDs for these expressions change because their context changes.
  Comparisons against reports made with earlier versions show them as removed
  `short_circuit` decisions and new `fallback` decisions.

## [0.11.1] - 2026-09-28

- Treat string, interpolated string, symbol, and numeric literal conditions as
  always truthy. Rules that need such a literal to be falsey, as in
  `name || "Item #{id}"`, are now excluded as statically impossible instead of
  being reported as missing with unknown reachability.

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
