# Branchproof usage guide

Branchproof measures decision, condition, modified condition/decision (MC/DC),
and decision-table coverage from one serial Minitest or RSpec run. It discovers Ruby
decisions through Prism, records their runtime paths, and attributes evidence
to tests. Boolean decisions receive the coverage ladder; `case`, pattern
alternatives, safe navigation, conditional assignments, and value fallback
chains such as `name || "untitled"` receive alternative coverage.

The gem and primary command are named `branchproof`. The `mcdc` command and
`MCDC` namespace remain compatibility aliases with the same behavior.

## Installation

```sh
gem install branchproof
```

Or add it to a bundle:

```sh
bundle add branchproof
```

Branchproof requires CRuby 4.0 or newer and Prism 1.x at runtime.
CI tests CRuby 4.0, including Rails 8.1.x and rspec-rails 8.x integrations.
Newer Ruby versions are allowed by the gem requirement but are not yet tested in CI.
The application supplies the test framework selected for analysis: Minitest
`>= 5.25.5, < 7` or RSpec 3.13. Branchproof does not install either framework;
projects that use both can keep both in their test bundle.
Unsupported syntax and incomplete observations remain visible in the report
instead of being counted as coverage.

For a Minitest application, keep the runner in the application bundle:

```ruby
gem "branchproof"
gem "minitest", ">= 5.25.5", "< 7"
```

For an RSpec application, use its existing RSpec bundle:

```ruby
gem "branchproof"
gem "rspec", "~> 3.13.0", require: false
```

`branchproof report`, `branchproof compare`, and `branchproof collate` read saved
JSON without loading either test framework, so reports can be used in a
minimal deployment or offline environment.

## Check a project's setup

Run `branchproof doctor` from the project root to check static setup facts before
starting an analysis:

```sh
bundle exec branchproof doctor 'lib/**/*.rb' \
  --test 'test/**/*_test.rb' \
  --project ruby --framework minitest
```

Doctor accepts source globs followed by `--test GLOB`, `--project
auto|ruby|rails`, `--framework auto|minitest|rspec`, `--config PATH` or
`--no-config`, and `--format terminal|json`. It uses the same project detection,
configuration precedence, framework selection, test discovery, and source
safety exclusions as `analyze`. Command-line selections override matching
`.branchproof.json` values. Default discovery excludes helper, support, and
fixture test files; an explicit `--test` glob selects those files when requested.
`--help` prints usage without inspecting the project.

Doctor exits 0 when its static checks pass, including warning-only results, and
2 when setup is blocked or the command is invalid. JSON is one document with
`schema_version: 1`, `command: "doctor"`, a `ready` or `blocked` status,
`runtime`, resolved `project` and `configuration`, `selection`, selected
`framework` metadata, `checks`, and `limitations`. Each check has a stable code,
`pass`, `warning`, or `error` status, and a message. Add `--format json` to get
this document on both successful and blocked checks, including configuration
and argument errors.

Framework availability comes from RubyGems metadata. An `activated` version is
already in the current process; a `discoverable` version is visible in the
current RubyGems environment but has not been activated. Doctor checks only the
selected framework, using Minitest `>= 5.25.5, < 7` or `rspec-core ~> 3.13.0`.
Discoverable metadata does not prove that a framework can load successfully.

Doctor is a static readiness check. It does not load source, helpers, tests,
framework code, or Rails; run a test runner; or inspect Ruby syntax. A ready
result does not verify Rails boot, actual framework test discovery, runner
compatibility, instrumentation, coverage, or whether a selected file contains
executable tests. It warns about Spring or Bootsnap only when already visible in
loaded features. Configured coverage minima are shown but not evaluated. As with
other Branchproof commands, Branchproof itself must load successfully, including
its supported Ruby runtime and core dependencies.

## Analyze a test run

Run `branchproof analyze` with the source files or globs to inspect, followed by
options. A second `--` separates Branchproof options from arguments passed to
the selected test framework:

```sh
branchproof analyze 'lib/**/*.rb' --test 'test/**/*_test.rb' \
  --level 3 \
  --format terminal \
  --output tmp/branchproof.txt \
  --limits branchproof-limits.json \
  -- --seed 1234
```

For a plain Ruby application, select the project policy explicitly when
running from the application root:

```sh
bundle exec branchproof analyze 'lib/**/*.rb' --project ruby --test 'test/**/*_test.rb'
```

For a Rails application, run the same command from the application root so
the application's bundle and Rails version remain in effect:

```sh
bundle exec branchproof analyze 'app/**/*.rb' --project rails --test 'test/**/*_test.rb'
```

Choose the test framework independently from project kind:

```sh
bundle exec branchproof analyze 'app/**/*.rb' --project rails --framework rspec
```

`--framework auto|minitest|rspec` is explicit about the adapter. Auto mode
selects RSpec when `.rspec` or `spec/**/*_spec.rb` markers exist and Minitest
when `test/**/*_test.rb` or `test/**/test_*.rb` markers exist. If both are
present, specify the framework. RSpec discovery uses `spec/**/*_spec.rb`; an
explicit `--test` selection remains authoritative. Project roots are resolved
explicitly, and report paths are relative to that root so reports from
different checkouts can be compared.

Install `rspec` in the application's test bundle; Rails applications also need
`rspec-rails`. RSpec reads its usual option files and `SPEC_OPTS`, including
helper requires, filters, ordering, and file or example-ID selectors. Selectors
from RSpec configuration replace default discovery. Combining those selectors
with an explicit Branchproof `--test` is rejected as ambiguous; ordinary filters
such as `--tag` and `--example` can accompany `--test`.

RSpec before hooks, eager `let!`, and around-hook prefixes own setup evidence.
The example body and helpers evaluated there own body evidence; after hooks,
mock cleanup, and around-hook suffixes own teardown evidence. Suite and context
hooks remain unattributed. Pending and skipped examples do not invent execution;
an unexpectedly passing pending example remains a failure.

RSpec support is serial: dry-run, bisect, DRb, custom runners, nested runs, and
repeated example attempts are rejected. Rails/RSpec supports Rails 8.1.x with
rspec-rails 8.x on CRuby 4.0. Feature and system specs use the in-process
Capybara `rack_test` driver; browser drivers require execution-context support
outside this release. Capybara is optional for apps that do not use those specs.

For a project rooted at the current directory, `--project auto` is the
default. It selects Rails only when both `config/application.rb` and
`config/environment.rb` exist; otherwise it selects a plain Ruby project.
Use `--project ruby` or `--project rails` to override detection. An explicit
Rails project without both boot files is a usage error.

Minitest defaults discover the sorted, de-duplicated union of
`test/**/*_test.rb` and `test/**/test_*.rb`. Helper, support, and fixture files
are excluded from that default set. `--test` remains authoritative when test
files are selected explicitly. The worker prepends the project's `lib` and
`test` directories (`lib` and `spec` for RSpec) to its child load path, so application `require` calls
resolve without changing the parent process.

Project defaults can be checked into `.branchproof.json` at the project root:

```json
{
  "schema_version": 1,
  "project": "rails",
  "framework": "minitest",
  "sources": ["app/**/*.rb"],
  "tests": ["test/**/*_test.rb"],
  "exclude": ["app/generated/**/*.rb"],
  "minimum": { "mcdc": 80 }
}
```

`project` accepts `auto`, `ruby`, or `rails`; `framework` accepts `auto`,
`minitest`, or `rspec`. `sources` and `tests` replace their corresponding
defaults, while `exclude` removes matching source files before inventory. A
configuration file may live elsewhere when passed with `--config PATH`; its
patterns are still resolved from the project root. Use `--no-config` to disable
the default file. Command-line project, framework, source, and test selections
take precedence over the file. Configured `exclude` patterns are applied
before source inventory and are recorded in run metadata for comparison.
`--config` and `--no-config` cannot be used together. RSpec configuration
selectors continue to conflict with an explicit test selection, including one
supplied by this file.

The `minimum` values are validated percentages from 0 through 100 for the five
supported criteria: `decision`, `condition`, `condition_decision`, `mcdc`, and
`decision_table`. A policy is evaluated against the exact numerator and
denominator counts in the report, so a value such as `66.67` is not rounded
before it is compared. The policy is recorded in JSON under
`coverage_policy`.

The command line can add or replace individual policy entries with repeatable
`--minimum` options. Use `criterion=threshold`, for example:

```sh
bundle exec branchproof analyze 'lib/**/*.rb' --minimum mcdc=80 \
  --minimum decision_table=75
```

CLI values take precedence over matching `minimum` keys from `.branchproof.json`.
Specifying the same criterion more than once on the command line is an error.
The five criteria are evaluated independently. A threshold met exactly passes;
a result below it fails. A requested gate with a zero denominator, unavailable
coverage, or incomplete observations or analysis is `unavailable`, and exits
with status 2. A below-threshold gate exits 1. A failed test run makes
requested policy gates unavailable and exits 2; without a policy, a failed test
run retains the existing exit status 1. With no policy, the existing report
exit behavior remains unchanged.

For a separate policy on changed decisions, use `--changed-since REF` with
repeatable `--minimum-changed criterion=threshold` options. The configuration
equivalent is `"minimum_changed": { "mcdc": 80 }`; CLI values override matching
entries. See [Changed-decision coverage and gates](#changed-decision-coverage-and-gates).

For a Minitest project, a focused configuration can select the library and
test trees directly:

```json
{ "schema_version": 1, "framework": "minitest",
  "sources": ["lib/**/*.rb"], "tests": ["test/**/*_test.rb"] }
```

For an RSpec project, use its spec patterns instead:

```json
{ "schema_version": 1, "framework": "rspec",
  "sources": ["app/**/*.rb"], "tests": ["spec/**/*_spec.rb"] }
```

Rails analysis boots the application inside the isolated worker after
Branchproof's loader and the selected framework hooks are installed. The
application's `rails_helper` owns requiring and configuring `rspec/rails` after
the loader; the helper must not require `branchproof` again. Selected specs
may require only `spec_helper` and run without booting Rails,
even when project detection selects Rails. Once Rails is loaded, Branchproof
requires an initialized application and enforces the Rails/RSpec support limits.
The child receives `RAILS_ENV=test`, `RACK_ENV=test`, `PARALLEL_WORKERS=1`,
`DISABLE_BOOTSNAP=1`, and `DISABLE_SPRING=1`; the invoking process environment
is unchanged. The Rails metadata in the report identifies the selected
project and Rails version.

`--output` writes the report through an atomic replacement. Without it, the
report is written to standard output. `analyze` accepts `terminal` (the
default), `json`, and `github`; `compare` accepts `terminal` and `json`.
`report` also accepts `html` for a portable offline page. JSON includes source identities, criterion and schema
versions, baseline status, diagnostics, completeness, observations, and
analysis fields.

The terminal format is a compact reading view of the same report. It keeps
JSON's full stable identifiers and schema unchanged, while shortening IDs to
eight-character prefixes (extending a prefix when two IDs collide) and
displaying known Minitest owners as `ClassName#test_method`. When test
metadata is unavailable, the owner falls back to its short ID. Level 3 adds
the witness pair or missing counterpart constraints beside each condition;
Level 2 and Level 3 also list named supporting tests. Repeated supporting-set
rows are collapsed in terminal output only.

RSpec owners use the example's `full_description` and positional `example_id`.
Terminal views include quoted rerun commands, including selectors for shared
examples. These selectors apply to the recorded spec revision. Comparisons
require matching spec and declaration digests before matching example owners;
changed specs and older reports without digests are treated conservatively.
Runner output streams to stderr while JSON reports remain on stdout.
Pending, skipped, fixed-pending, and failed examples map to the corresponding
baseline statuses; suite and context lifecycle events remain visible, and
observations without a test owner are counted as unattributed. The same levels
and terminal views are available for both adapters.

For example, running the contents of the small `decision.rb` /
`test_decision_test.rb` fixture from a project `lib/` and `test/` directory
with the terminal format produces a summary like this:

```text
Branchproof 0.5.0
Tests: PASSED (3 tests, 0 failed, 0 skipped)
MC/DC: 100.0% (2/2 conditions proven)
Analysis: COMPLETE
Decisions: 1 supported, 0 excluded, 0 unexecuted (1 discovered)
Observations: 3 completed, 0 aborted, 0 unattributed
Values: T=true, F=false, -=short-circuited
Scope: supported decisions and conditions

Decision dde7aede lib/decision.rb:7
  Decision: left && right
  Status: SUPPORTED
  Condition 0: left
    PROVEN (witness 484eab21 + 8908881e)
  Condition 1: right
    PROVEN (witness e5ec8058 + 8908881e)
  Vector e5ec8058 [TF] => F owners=CliFixtureTest#test_true_false_vector
  Vector 8908881e [TT] => T owners=CliFixtureTest#test_true_true_vector
  Vector 484eab21 [F-] => F owners=CliFixtureTest#test_false_true_vector

Supporting sets:
  Vectors (EXACT_MINIMUM, decisions: [dde7aede]): 484eab21, 8908881e, e5ec8058
  Tests (EXACT_MINIMUM, decisions: [dde7aede]): CliFixtureTest#test_true_true_vector, CliFixtureTest#test_false_true_vector, CliFixtureTest#test_true_false_vector
Additional tests outside this MC/DC evidence set may improve coverage.
```

The test execution still runs once for the selected level. Use `--format
json` when a consumer needs the complete identifiers and versioned schema.

### Coverage ladder

Each successful `analyze` run calculates five criteria from the same completed
observations. The report shows their status for each supported decision and
aggregate counts with explicit denominators:

| Criterion | Requirement | Aggregate denominator |
| --- | --- | --- |
| Decision | The decision produced both true and false | Supported decisions |
| Condition | Every atomic condition evaluated both true and false | Two required truth values per supported condition |
| Condition/Decision | Both Decision and Condition Coverage hold for a decision | Supported decisions |
| MC/DC | Every condition has an independence witness pair | Supported conditions |
| Decision Table | Every executable logical rule was exercised | Non-impossible generated rules |

For `logged_in? && admin?`, observations `[F-] => F` and `[TT] => T` give:

```text
Decision                    PASS
Condition                   FAIL (3/4 values observed)
Condition/Decision          FAIL
MC/DC                       FAIL (1/2 conditions proven)
Decision Table              FAIL (2/3 rules covered)
```

The skipped `admin?` in `[F-]` counts as neither true nor false. Conditions
that did evaluate count toward Condition Coverage even when their value was
masked by another condition. Here, the two observations prove independence
for `logged_in?`; `admin?` still needs `[TF] => F`.

This is also a compact test-design walkthrough. A test that records
`[F-] => F` proves the false branch of `logged_in?`; a test that records
`[TT] => T` proves the true branch and establishes the current positive path.
Adding a test that records `[TF] => F` evaluates `admin?` false while
`logged_in?` stays true, so it supplies the missing independence witness and
improves the condition, Condition/Decision, MC/DC, and applicable decision-table
results. The report names the missing vector and its owning test when it is
observed.

Decision and Condition Coverage are calculated independently from the captured
evidence. Condition/Decision requires both; MC/DC adds independence evidence.
Decision Table Coverage is calculated independently of all of them: MC/DC asks
whether each condition can independently affect the outcome, while Decision
Table Coverage asks whether each logical rule was exercised. Neither status is
inferred from the other, so `MC/DC PASS` with `Decision Table FAIL` and the
reverse are both valid results.

Unsupported decisions are excluded from every denominator, while
unexecuted supported decisions remain in scope. Empty denominators are N/A.

Reports retain the observations and owning tests for each decision outcome
and condition value. Missing values describe required runtime observations,
not application inputs or a guarantee that the path is reachable. Unattributed
observations can provide truth-value evidence without identifying a test;
the report's completeness and diagnostics still apply.

JSON stores aggregate counts under `analysis.coverage`, per-decision results
under `analysis.decisions[].coverage`, and condition value evidence under
`analysis.decisions[].condition_results[].coverage`. Existing MC/DC witness
pairs, counterpart constraints, and raw vectors remain available. Statuses
distinguish `covered`, `partial`, `unexecuted`, and `unsupported` results.

### Decision table coverage

For a Boolean decision Branchproof can represent with `AND`, `OR`, `NOT`, and
atomic conditions, it derives a reduced decision table statically from the
Boolean structure and then overlays the runtime evidence of the same run. No
application code is executed while the table is derived, and no extra test run
is performed while it is overlaid.

Rules come directly from the short-circuit evaluation paths of the Ruby expression,
so a condition the interpreter would
skip appears as an explicit don't-care (`-`) rather than as two separate rules.
Exhaustive Boolean expansion is deferred; it is not required to calculate coverage
and is never performed on the reporting path.
For `premium? && (admin? || owner?)`:

```text
Decision Table: 3/4 rules covered (75.0%)
  Rule  premium?  admin?  owner?  Result  Status
  R1    F         -       -       F       COVERED
  R2    T         T       -       T       COVERED
  R3    T         F       T       T       MISSING
  R4    T         F       F       F       COVERED
  R1 tests: UserAccessTest#test_free_user
  R2 tests: UserAccessTest#test_admin
  R3
  Need:
    premium? = truthy
    admin?   = falsey
    owner?   = truthy
  Expected decision:
    true
  Reachability:
    unknown
  R4 tests: UserAccessTest#test_denied
```

A missing rule describes condition values only. It does not claim which
application inputs would produce them.

An observation matches a rule when every required condition value matches and
the decision outcome matches. Conditions Ruby skipped can only line up with
don't-care positions; they never satisfy a required true or false. Every rule
carries a stable identity derived from the decision, its normalized condition
vector, the expected outcome, and the table schema version — never from a test
name, an observation order, or the Minitest seed, so saved reports compare
across runs.

Decision tables are derived for `if`, `unless`, `elsif`, ternary, `while`,
`until`, subjectless `case`/`when`, and supported Boolean pattern guards.
Multi-way `case`/`when`, `case`/`in` alternatives, safe navigation, conditional
assignment, and exception handling keep their alternative coverage model and
produce no Boolean table.
For `unless` and `until`, the outcome is the predicate value, not whether the
body executes; the terminal report labels it accordingly.

#### Reachability and impossible rules

Each rule carries a reachability status: `observed`, `unknown`, or
`statically_impossible`. Branchproof proves impossibility or leaves
reachability unknown. It never infers impossibility from a missing test, a
missing observation, application conventions, Rails validations, database
constraints, comments, or method names.

Constraint analysis version 2 requires evidence that a constraint is safe before
using it to exclude a rule. A variable name and a numeric literal do not prove
that the receiver is a number, that its comparison methods use built-in semantics,
or that its value stays unchanged. Numeric, equality, and nil-check expressions
are still normalized for inspection, but unproven source constraints remain
`unknown`. The standalone constraint solver describes its explicit model, not
arbitrary Ruby objects.

Literal truth values can establish impossibility without invoking application
methods. For `age && false`, the rule requiring the literal `false` to be truthy
cannot execute:

```text
Decision Table: 2/2 rules covered (100.0%)
Statically impossible rules excluded: 1
  Rule  age  false  Result  Status
  R1    F    -      F       COVERED
  R2    T    F      F       COVERED
  R3    T    T      T       EXCLUDED
  R3 TT => T
  Status:
    EXCLUDED
  Reachability:
    STATICALLY IMPOSSIBLE
  Reason:
    conflicting Boolean literal requirements
```

Impossible rules stay visible in the full report but leave the coverage
denominator. Reason codes are stable: `conflicting_numeric_bounds`,
`conflicting_equalities`, `equality_outside_numeric_range`, `nil_conflict`, and
`boolean_literal_conflict`. Human-readable messages may change independently.

Runtime evidence is authoritative. If an observation matches a rule the static
model called impossible, the rule becomes `observed`, the impossibility claim is
withdrawn, the rule returns to the denominator, and a `constraint_model_conflict`
diagnostic records the disagreement.

For example, `age > 10 && age < 5` stays unknown without a proven domain;
custom comparison methods can make both comparisons true. Similarly,
`x > 10 && (x = 0) && x < 5` can execute successfully. `Float::NAN` also prevents
treating a false comparison as its ordered complement. Runtime evidence can cover
these rules, but lack of evidence cannot exclude them. Ruby truthiness remains
distinct from Boolean equality: only `false` and `nil` are falsey.

Use `analyze --no-reachability` to disable all static exclusions, including literal
proofs. Every generated rule then remains an obligation; reports show
`Reachability: not analyzed`. The mode is persisted with the report and considered
when comparing analysis contexts. Reading a saved report preserves its original
analysis; it does not recalculate it under a different mode.

#### Decision table views and limits

`--view decision-tables` groups the terminal report by decision table, and
`--missing-only` narrows it to uncovered, non-impossible rules while retaining
uncalculated decisions with their location and reason. `decision_tables` is an
accepted compatibility spelling for the view:

```sh
bundle exec branchproof analyze 'lib/**/*.rb' \
  --view decision-tables \
  --missing-only
```

Tables grow exponentially with condition count, so
`max_conditions_for_decision_table` (default 12) and
`decision_table_rules_per_decision` (default 4096) bound the derivation. A
decision above either limit reports `Decision Table: NOT CALCULATED` with the
reason `decision_table_condition_limit_exceeded` or
`decision_table_rule_limit_exceeded` instead of a partial table.

JSON stores the table under `analysis.decisions[].decision_table` with its
`schema_version`, `constraint_analysis_version`, rules, rule identities, rule
coverage, test attribution, reachability, and reachability reason. This abbreviated
example omits counts and evidence bookkeeping fields; full reports also retain
rule indexes, vector IDs, unattributed counts, and withdrawn-impossibility details:

```json
{
  "decision_table": {
    "status": "calculated",
    "schema_version": 1,
    "constraint_analysis_version": 2,
    "rules": [
      {
        "id": "8f1c...",
        "label": "R1",
        "conditions": ["false", "dont_care", "dont_care"],
        "outcome": false,
        "coverage": "covered",
        "reachability": "observed",
        "tests": ["..."]
      },
      {
        "id": "3ad0...",
        "label": "R3",
        "conditions": ["true", "false", "true"],
        "outcome": true,
        "coverage": "missing",
        "reachability": "unknown",
        "tests": []
      }
    ]
  }
}
```

Aggregate counts live under `analysis.coverage.decision_table` and keep rule
coverage and fully covered decisions as distinct metrics:

```text
DT (Decision table coverage): 83.9% (47/56 rules)
Decision tables fully covered: 13/18 decisions
```

### Find missing cases

Use `--missing-only` to focus terminal and HTML reports on conditions that still
lack independence evidence:

```sh
bundle exec branchproof analyze 'lib/**/*.rb' --missing-only
```

This keeps the overall summary and diagnostics, hides proven conditions and
supporting-set lists, and shows missing scenarios using the source expressions.
It works with levels 2 and 3 (the default). JSON remains the complete report;
`--missing-only` cannot be combined with `--format json` or `--level 1`.

For example, given this decision:

```ruby
content && Instruction.installed?(content)
```

Observing `[TT]` and `[F-]` proves the effect of `content`, but does not prove
the effect of `Instruction.installed?(content)`. The missing case is `[TF]`:
`content` must be truthy and `Instruction.installed?(content)` must be falsey,
making the decision false. The missing condition is presented as:

```text
  Condition 1: Instruction.installed?(content)
    NOT_PROVEN — Missing evidence for: Instruction.installed?(content)
      Observed decision expression: content && Instruction.installed?(content)
      Find two executions where:
        Instruction.installed?(content) changes between true and false
        content remains true
        decision outcome changes between true and false
      Observed: content = true; Instruction.installed?(content) = true; decision = true
      Missing counterpart: content = true; Instruction.installed?(content) = false; decision = false (candidate; not observed)
      Boolean requirement; application-level feasibility unknown
```

An existing file without the instruction block
may produce this case; the test must reach the reported line. The report
describes required truth values, not application inputs or guaranteed
reachable paths. In Ruby, only `false` and `nil` are falsey; an empty string
is truthy.

This wording is generated from recorded expressions and analyzer candidates.
Boolean values describe truthiness, not the original Ruby objects. Short-circuited
conditions are marked as not evaluated. Unary negation remains in the full
decision expression: for `user.paid? && !user.suspended?`, the atomic condition is
`user.suspended?`, so its observed value is `false` and the missing counterpart
requires `true`. No domain wording or application inputs are inferred.

`NOT_PROVEN` means analysis ran but did not find the required pair of
observations. `NOT CALCULATED` means analysis was not available or was not
requested; check the test status and diagnostics before adding tests.
`Analysis: COMPLETE` means the analysis finished, not that every condition
was proven. Missing conditions may require new tests or changes to existing
test inputs; they do not by themselves prove a bug in the application.

The levels select how much of the one-run result is displayed:

* Level 1 reports the coverage ladder and observed vectors grouped by their
  raw decision outcomes.
* Level 2 includes the smallest supporting sets found for vectors and tests.
* Level 3 (the default) includes condition independence witnesses and
  counterpart constraints, as well as the Level 1 and 2 evidence.

All levels calculate the same criteria from one captured run. The level
controls displayed evidence, not the coverage criterion; JSON retains the
analysis even at Level 1. A failed, unsupported, or incomplete run is reported
with its status and diagnostics and cannot become a successful coverage
result by changing the display level.

### Focused condition, test, and decision-table views

Use `--view conditions` to group the report by condition. Each condition shows
its expression, decision, and project-relative source location with the
condition's own 1-based start line. The view separates tests that evaluated
the condition true or false from tests where it was short-circuited. Level 3
also shows the canonical witness observations selected by the analyzer and
their owning tests.

```sh
bundle exec branchproof analyze 'lib/**/*.rb' --view conditions
bundle exec branchproof analyze 'lib/**/*.rb' --view conditions --missing-only
```

Use `--view tests` to group the same evidence by test. Rows include each
exercised condition, its relative source location, observed values, and the
recorded `setup`, `body`, or `teardown` phases. Tests with no completed
condition observation remain visible, as do unattributed and unexecuted
conditions. A test that evaluates both Boolean values is evidence of execution;
it is a proof contributor only when the analyzer's independent witness pair
uses its observations.

Use `--view decision-tables` to group the report by decision table. See
[Decision table coverage](#decision-table-coverage) for the rule, reachability,
and attribution detail it renders.

`--view` changes terminal grouping and does not change instrumentation or test
execution. JSON output always contains the complete evidence document, so an
explicit view cannot be combined with `--format json`. The `mcdc` executable
accepts the same arguments for existing scripts.

Terminal and HTML reports can be narrowed with `--focus PATH[:LINE]` and bounded with
`--top N`, where `N` is a positive integer. These options are accepted by
`analyze` and `report`; for HTML they apply only to offline `report`. Focus matches the source spans
captured in the report; rendering does not reopen or need the original source
file. `--focus` and `--top` affect displayed detail only: the coverage summary,
policy gates, diagnostics, exit status, and global counts remain unchanged.

The default view limits decisions. In `--view decision-tables`, the units are
decision tables; in `--view conditions`, condition and alternative rows; and
in `--view tests`, test rows. Rows are ordered deterministically by project-
relative path and source line, with deterministic tie-breakers for each view:
decisions use column and stable ID; decision tables use decision ID; conditions
and alternatives use column, decision ID, and condition or alternative index;
tests use test name and ID. `--top` follows that source order; it does not rank
rows by risk or coverage. Only `--view summary` ranks rows (see
[Summary view](#summary-view-where-to-start)). For example:

```sh
bundle exec branchproof analyze 'lib/**/*.rb' --focus lib/access.rb:12 --top 5
bundle exec branchproof report .branchproof/current.json --view conditions \
  --focus lib/access.rb --top 10
```

Focus and top selections never create a new test run or alter policy scope.
They also do not generate tests. RSpec rerun labels remain the existing
recorded selectors and commands. The main finding rows respect the selection;
supplemental unexecuted, unattributed, and unsupported sections retain their
run-wide counts rather than expanding into all detail rows.

### Summary view: where to start

Use `--view summary` to see the largest gaps first. It is accepted by
`analyze` and `report` and is terminal-only.

```sh
bundle exec branchproof analyze 'lib/**/*.rb' --view summary --top 10
bundle exec branchproof report .branchproof/current.json --view summary
```

The view has two ranked lists:

* **Files**: one row per source file, with counts and explicit denominators.
* **Where to start**: one row per supported decision that still has a gap,
  with its location, the missing cases, and the tests that already reach it.

Both lists use the same deterministic order:

1. Unexecuted decisions (or files with more of them) come first.
2. Then more missing obligations: decision-table rules, unproven MC/DC
   conditions, and missing alternatives.
3. Ties break by project-relative path, line, column, and decision ID.

The order counts missing obligations. It is not a risk estimate.

```text
Files:
  1. lib/access.rb: 3/3 decisions with gaps; 1 unexecuted; DT 8/11 rules missing; MC/DC 7/8 conditions unproven
  2. lib/pricing.rb: 2/2 decisions with gaps; DT 2/3 rules missing; MC/DC 2/2 conditions unproven; 2/3 alternatives missing

Where to start:
  1. lib/access.rb:15  a && (b || c)
     unexecuted; DT 4/4 rules missing; MC/DC 3/3 conditions unproven
     Cases to test: 4
     R1 [F--]: a falsey; expected decision false
     R2 [TT-]: a truthy, b truthy; expected decision true
     R3 [TFT]: a truthy, b falsey, c truthy; expected decision true
     R4 [TFF]: a truthy, b falsey, c falsey; expected decision false
     Tests reaching this decision: none recorded

  2. lib/access.rb:7  user.owner?(doc) || (user.editor? && !doc.locked?)
     DT 3/4 rules missing; MC/DC 3/3 conditions unproven
     Cases to test: 3
     ...
     Tests reaching this decision:
       AccessTest#test_owner (test/access_test.rb:19)
```

`Cases to test` counts the new observations the decision needs. When the
decision table was calculated, each missing rule is one case, and one
observation can cover at most one rule. When the table was not calculated,
or no rule is missing but a condition is still unproven (for example, when
its pair needs a statically impossible rule), the view lists the unproven
conditions instead. For decisions with
alternative coverage, such as `case`/`when` or `case`/`in`, it lists the
missing alternatives. A case describes truth values, not application inputs.

The level controls detail per row:

* Level 1 shows ranked rows and counts only.
* Level 2 adds the missing cases.
* Level 3 (the default) also names up to three tests that already reach the
  decision, with RSpec rerun commands when recorded. These tests are good
  places to add the new case.

`--top N` keeps the first `N` rows of each list and reports how many were
hidden. `--focus PATH[:LINE]` ranks only the matching decisions.
`--missing-only` hides fully covered files. Unsupported decisions are counted
but not ranked. As with the other views, the coverage ladder, policy gates,
diagnostics, and exit status are always global.

### Saved reports and offline comparison

Reports are saved only when requested. Create a local artifact directory and
write a complete JSON baseline with the existing atomic `--output` option:

```sh
mkdir -p .branchproof
bundle exec branchproof analyze 'lib/**/*.rb' --format json \
  --output .branchproof/baseline.json
bundle exec branchproof report .branchproof/baseline.json --view conditions
bundle exec branchproof report .branchproof/baseline.json --view tests
bundle exec branchproof report .branchproof/baseline.json --format html \
  --output .branchproof/coverage.html
```

The output's parent directory must already exist. Replacing a baseline is an
explicit `analyze --format json --output` operation; keep CI snapshots as
artifacts when you need to retain multiple runs.

The `report` command reads the saved document without loading the application,
project configuration, or running tests. It uses locations and metadata
captured in the report, so rendering remains useful after the original
checkout has moved or been removed. A saved report's policy is inherited by
default. Repeatable `--minimum criterion=threshold` options override matching
saved policy entries for that rendering without changing the snapshot file;
other saved thresholds remain inherited. Offline rendering never consults the
current `.branchproof.json`.

HTML is a single self-contained document with inline CSS, no JavaScript, external
assets, source reads, or network requests. It can be written to a file with
`--output` or streamed to stdout. The page keeps whole-run coverage and policy
global even when `--focus`, `--top`, or `--missing-only` filters displayed
decisions. Its status and exit code still reflect the saved run and its policy.
HTML is available from `report` and `collate`; `analyze` and `compare` reject it. The
integrated HTML layout does not accept `--view`. At level 1 it shows the summary
and decision inventory; level 2 adds missing scenarios; level 3 also adds
contributing tests. Legacy snapshots without analysis support only level 1,
and HTML reports failed or incomplete runs with their existing exit status.

New live JSON reports use schema `1.4` and include the required
`coverage_policy` object with the normalized requested minima and recomputed
gate results. The report validates those results from its exact coverage
counts rather than trusting a persisted percentage. Reports created with
`--changed-since` use schema `1.5` and add the captured changed scope and its
informational coverage. A changed policy adds `changed_coverage_policy` and uses
schema `1.6`. Collated reports use schema `1.7` and record their contributing
shards and collection completeness. Readers accept schemas `1.0` through `1.7`.
A whole-run policy overlay preserves the input schema; adding a changed policy to a `1.5` snapshot
upgrades the output to `1.6` without changing the input file.
Policy overlays on collated reports preserve schema `1.7` and its provenance.
New snapshots retain the ladder at every level. Legacy snapshots without
analysis can still be rendered at Level 1; levels 2 and 3 require analysis in
the saved report.
The repository ignores `.branchproof/`; choose a different path and CI artifact
policy when a project needs to retain reports.
Saved JSON includes existing raw metadata such as test names and expressions;
relative terminal labels do not mean every legacy JSON field is sanitized.

### Combine serial test shards

When CI splits tests into separate jobs, save a JSON report from each serial
run and combine their observations offline:

```sh
bundle exec branchproof collate unit.json integration.json \
  --manifest shards.json --output combined.json
bundle exec branchproof report combined.json --format html --output coverage.html
```

Collation recalculates coverage, supporting sets, missing evidence, and gates.
For example, a true decision in one shard and a matching false decision in
another can together prove a condition's effect. Shard coverage percentages
are never averaged. No application code or tests run during collation, and the
original checkout does not need to exist.

Declare the expected artifacts in `shards.json`:

```json
{
  "shards": [
    { "id": "unit", "report": "unit.json" },
    { "id": "integration", "report": "integration.json" }
  ]
}
```

Manifest paths are relative to the manifest file. Pass the artifacts actually
received as command arguments; omitted entries stay missing even if their
files happen to exist. Unknown inputs and duplicate manifest IDs or paths are
rejected. One artifact cannot satisfy two different shard IDs.

The manifest is optional. Without it, collation displays the supplied evidence
but marks collection completeness unknown and exits **2**. Missing declared
shards also produce an incomplete report and exit 2. A complete manifest proves
only that every declared artifact arrived; it does not prove those artifacts
selected every test in the application. Failed or incomplete input runs cannot
become a passing collection.

Inputs must be raw schema `1.4`–`1.6` reports from the current Branchproof and
Ruby runtime, with matching report schema, source inventory/digests, framework,
limits, reachability settings, analysis level, and coverage thresholds. Captured
changed scope and changed thresholds must also match. Different test selections,
seeds, and checkout roots are allowed; per-shard metadata and relative test
locations are retained. Missing reconstruction metadata is an error. Collated
reports cannot themselves be collated in this first version.

An identical report supplied twice is counted once. Conflicting or partially
overlapping run IDs are rejected. A test executed in different runs contributes
each execution to baseline counts and phase counts, while retaining its existing
test identity; any failure takes precedence over a later pass.

Collate defaults to JSON and supports `--format terminal|json|github|html`.
Use `report` for views, display filters, or threshold overrides on the saved
result. Output is written atomically and cannot replace input reports, declared
artifacts, or the manifest. Combined evidence exceeding storage limits is
rejected; bounded analysis that cannot finish remains incomplete. Schema `1.7`
requires an updated reader. Collation does not enable threaded or forked runners.

### Changed-decision coverage and gates

The analyze-only `--changed-since REF` option resolves `REF` to a commit and compares that
commit directly with the current tracked worktree, including staged and
unstaged edits. It does not infer a merge base. Untracked files are excluded.
The option adds informational coverage for current decisions mapped to changed
source lines; it does not select or skip tests. Additions and renames include
all current decisions in their files, deletions have no current decision
obligation, and comment or spacing changes with no semantic decision change
produce an empty scope. Invalid refs, non-Git projects, and observed source or
Git drift fail with usage status 2 before tests start. Capture checks for drift
but does not lock the checkout atomically.

The full inventory, analysis, run metrics, and `--minimum` gates remain
whole-run. A whole-run minimum can fail even when changed coverage is complete.
Add `--minimum-changed` to enforce an independent changed-decision threshold:

```sh
bundle exec branchproof analyze 'lib/**/*.rb' --changed-since main \
  --minimum-changed mcdc=80
```

The changed gate uses exact counts for the captured changed decisions and the
same five criteria as `--minimum`. For example, 1 of 2 conditions proven means
50% MC/DC: an 80% gate fails even when every test passes. Add the missing
independence evidence and 2 of 2 conditions passes. Both policies must pass when
both are configured. A changed minimum requires `--changed-since` during
analysis; missing scope is rejected before tests run.

A valid empty changed scope is `not_applicable`, with no coverage percentage.
It does not fail the run or waive failed tests, incomplete evidence, or whole-run
gates. A nonempty scope with only unsupported decisions, or a requested criterion
with no applicable denominator, is unavailable. As with whole-run gates, a failed
test run makes a requested changed gate unavailable. Below-threshold gates exit
1; unavailable gates exit 2.

Terminal focus and top filters intersect the changed decision IDs for display;
they do not change either coverage denominator. JSON accepts the scope option,
while its existing focus and top restrictions remain. Saved reports retain the
captured scope for offline rendering without Git access. Their validation
checks the scope's internal consistency, not the historical Git diff or
cross-revision coverage.

```sh
bundle exec branchproof analyze 'lib/**/*.rb' --changed-since main
bundle exec branchproof report .branchproof/current.json --minimum-changed mcdc=80
```

Offline reports inherit saved changed thresholds and allow matching overrides.
They use the captured scope without consulting Git or project configuration.
Terminal, GitHub, and HTML output show changed gate results separately from
whole-run gates.

To compare two explicitly saved runs:

```sh
bundle exec branchproof analyze 'lib/**/*.rb' --format json \
  --output .branchproof/current.json
bundle exec branchproof compare .branchproof/baseline.json \
  .branchproof/current.json
bundle exec branchproof compare .branchproof/baseline.json \
  .branchproof/current.json --fail-on-regression
```

Comparison matches exact condition identities from unchanged source files.
Changed source files, changed selection or runtime context, incomplete runs,
and legacy reports missing comparison metadata are reported as partial or
incomplete context rather than guessed regressions. The output distinguishes
gained proof, lost proof, changed sources, newly selected files, and files no
longer present in a report. Previous witness values and owner names are shown
for lost proof; an absent owner is described as `not observed in current run`,
not as a deleted test. A different test population under unchanged discovery
patterns is valid comparison context, and seed differences are disclosed.

`compare` exits 0 for a complete comparison, including one with coverage
changes; `--fail-on-regression` exits 1 when a complete comparable run loses
MC/DC proof or decision-table rule coverage. The JSON `regression` flag includes
either kind of loss; `regressions` retains the MC/DC count and
`decision_table_regressions` supplies the separate rule-loss count. Changes to
table schemas, constraint-analysis versions, or reachability modes are reported
as analysis context changes rather than silently treated as unchanged analysis.
Invalid input or an incomplete comparison exits 2, which takes
precedence. Reports are explicit snapshots: comparison never creates history,
promotes a baseline, or overwrites either input.

### GitHub Actions artifacts

A coverage policy can fail a job while still preserving the report for review.
Create the output directory before invoking Branchproof and upload the report
with `if: always()` so failed gates and failed test runs leave an artifact:

```yaml
- name: Branchproof coverage
  run: |
    mkdir -p .branchproof
    bundle exec branchproof analyze 'lib/**/*.rb' --test 'test/**/*_test.rb' \
      --format json --output .branchproof/coverage.json \
      --minimum mcdc=80 --minimum decision_table=75

- name: Upload Branchproof report
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: branchproof-coverage
    path: .branchproof/coverage.json
    if-no-files-found: warn
```

To attach a portable HTML report as well, render it from the saved JSON and
upload both files. The report step is offline and does not run tests again:

```yaml
- name: Render Branchproof HTML
  if: always() && hashFiles('.branchproof/coverage.json') != ''
  run: >-
    bundle exec branchproof report .branchproof/coverage.json --format html
    --output .branchproof/coverage.html

- name: Upload Branchproof reports
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: branchproof-coverage
    path: .branchproof/coverage.*
    if-no-files-found: warn
```

### GitHub Actions annotations and job summary

`--format github` prints GitHub Actions workflow commands instead of the
terminal report. `analyze` and `report` accept it; `compare` does not.

* One `::warning` per decision with a gap, in [summary view](#summary-view-where-to-start)
  order, placed on the decision's file and line. At level 2 or 3 the message
  lists the cases to test.
* An `::error` if the test run did not pass or is incomplete, and one per
  policy gate that did not pass (failed or unavailable, with its reason).
  Every non-zero exit status has at least one error.
* A final `::notice` with the coverage ladder and the number of decisions with
  gaps.

When `GITHUB_STEP_SUMMARY` is set, as it is inside Actions, Branchproof also
appends a Markdown summary to that file: the ladder, the policy gates, and a
ranked "Where to start" table. The table shows `--top N` rows, or 20 rows
when `--top` is not given.

Render both from the saved report, so the tests run only once:

```yaml
- name: Branchproof coverage
  run: |
    mkdir -p .branchproof
    bundle exec branchproof analyze 'lib/**/*.rb' --test 'test/**/*_test.rb' \
      --format json --output .branchproof/coverage.json \
      --minimum mcdc=80 --minimum decision_table=75

- name: Branchproof annotations
  if: always() && hashFiles('.branchproof/coverage.json') != ''
  run: bundle exec branchproof report .branchproof/coverage.json --format github --top 10
```

GitHub shows a limited number of annotations per step (currently 10
warnings), so `--top 10` keeps the output to the ones that are displayed.
Annotation paths must be relative to the repository. When the project is in
a subdirectory (a step with `working-directory: gems/tool`), Branchproof
prefixes each path with the current directory's location inside
`GITHUB_WORKSPACE`. Run `report` from the same directory as `analyze`.

`--focus` also applies. `--view` and `--missing-only` are rejected because
the output always uses the summary ranking of gaps. The exit status is the
same as for the terminal format, so the report step inherits the saved
policy and fails with the same gates.

MC/DC has two related questions. Evaluation asks whether a condition was
observed with a value, including short-circuiting. Independent proof asks
whether the analyzer found a pair of observations where that condition changes
the decision outcome under the masking criterion. Other conditions may be
short-circuited or masked rather than fixed to the same observed values. For example,
`left && right` observed as `[TT]` and `[F-]` evaluates `right` once and
short-circuits it once, but does not prove `right`; `[TF]` is also required.
The condition and test views preserve that distinction.

### Supported decision forms

Every decision has a stable `kind` and `context` in JSON. The Boolean ladder
applies to the following forms:

| Construct | Kind | Context |
| --- | --- | --- |
| `if`, modifier `if`, `elsif`, `unless`, ternary | `boolean` | `if`, `elsif`, `unless`, `ternary` |
| `while`, `until`, including modifier and post-test loops | `boolean` | `while`, `until` |
| Each subjectless `case` candidate | `boolean` | `case_when` |
| Standalone `value in pattern` | `boolean` | `pattern_in` |
| Evaluated pattern guard predicate | `boolean` | `pattern_guard` |
| Standalone `&&`, `||`, `and`, `or` | `boolean` | `short_circuit` |
| Value-context `predicate || raise(...)`, `fail(...)`, or a jump | `boolean` | `guard` |

Prism determines precedence. `!` and `not` appear as NOT nodes in the Boolean
tree; their operands remain the conditions. Short-circuited operands remain
not evaluated. A Boolean subtree already decomposed in a decision is not
inventoried again as a standalone decision.

Loop outcomes describe the predicate as written: an `until` predicate that
returns true ends the loop. Every predicate evaluation receives an execution
ID. Repeated equivalent executions aggregate into a vector's `count`, retaining
the supporting tests. Ternary outcomes likewise describe the predicate, not
the value returned by the chosen branch.

For a value-context guard such as `storage || raise(ArgumentError, "missing")`
or `storage || return`, the reported decision is `storage`, with context
`guard`. Its true outcome skips the right-hand side; its false outcome selects
it. Evidence is completed before the right-hand side executes, so a test that
expects the exception or early return contributes the false outcome. Testing
both paths can prove decision, condition, MC/DC, and decision-table coverage
without a manual disposition. For `a || b || raise(...)`, the guard predicate
is `a || b`, so both conditions retain their independent-effect obligations.

Guard coverage proves this branch choice, not the value returned by the entire
`||` expression or successful completion of the right-hand side. An application
may redefine `raise` or `fail` to return a value; that does not change what the
guard measures. Decisions inside the call's arguments remain separate.

This classification recognizes receiverless `raise`/`fail` calls and
`return`, `break`, `next`, `redo`, and `retry`, optionally inside single-expression
parentheses. Predicate contexts (`if storage || raise(...)`), keyword `or`,
explicit receivers (`receiver.raise(...)`), and compound right-hand-side blocks
keep their existing classification. This does not change how aborted traces
from arbitrary predicates are counted. Guard decision IDs differ from the old
whole-expression `short_circuit` IDs; regenerate saved baselines and dispositions
that reference those IDs when adopting this behavior.

Value decisions remain enabled by default. For each decision, evidence caches
the most recent successful completed trace, keyed by its observations, outcome,
test, and phase. Consecutive equivalent executions increment vector and phase
counts without repeating serialization and digest work. When observations,
test, or phase changes, the execution is recorded normally, so alternating
traces retain their full evidence and attribution.

Other constructs use alternative coverage, separate from MC/DC:

| Construct | Kind | Context | Required alternatives |
| --- | --- | --- | --- |
| `case subject` | `multiway` | `case` | Each `when` candidate and `else` (or implicit no-match path) |
| `case/in` | `pattern` | `case_in` | Each pattern clause and explicit `else`, if present |
| `receiver&.method` | `implicit` | `safe_navigation` | Receiver nil / non-nil |
| `lhs ||= rhs` | `implicit` | `or_assignment` | RHS skipped / executed |
| `lhs &&= rhs` | `implicit` | `and_assignment` | RHS skipped / executed |
| `receiver&.value ||= rhs` / `&&=` | `multiway` | `or_assignment` / `and_assignment` | Receiver nil / RHS skipped / RHS evaluated |
| `value => pattern` | `pattern` | `required_pattern` | Matched / mismatch |
| Rescue regions | `exception` | `rescue` | Normal completion / rescue clause / unhandled exception |
| Optional positional and keyword arguments | `implicit` | `default_argument` | Supplied / default evaluated |
| Standalone predicate calls | `implicit` | `predicate` | Falsey / truthy result |
| `<=>` | `multiway` | `comparison` | Negative / zero / positive / nil |
| `[]` lookup | `multiway` | `lookup` | Truthy / false / nil result |
| `send`, `public_send`, and `__send__` | `implicit` | `dispatch` | Successful return / exception |
| Regular-expression match capture | `implicit` | `match_capture` | False / true |
| Iterator bodies | `implicit` | `iteration` | Empty / entered |
| Lazy iterator callbacks | `multiway` | `lazy_callback` | Callback entered |
| `fetch` with a fallback block | `implicit` | `fetch_fallback` | Value present / fallback entered |

Each safe-navigation operation in a chain is a distinct decision. Assignment
instrumentation preserves Ruby's native local, instance, class, global,
constant, method, and indexed assignment operations, including receiver and
index evaluation order. Safe navigation distinguishes nil from false.

For multiway decisions, vector values mean selected (`true`), evaluated but
not selected (`false`), and skipped (`null`). Later alternatives remain skipped
when an earlier candidate matches. Implicit vectors record the selected path
and its unselected complement. Their `outcome` is a selection marker, not the
truthiness of the application's return value. Reports label these as paths,
not Boolean outcomes. Each alternative exposes selected, not-selected, and
skipped evidence with test and vector IDs. The alternative denominator is the
number of supported selectable alternatives; these decisions do not enter
Boolean-ladder or MC/DC denominators.

A `case/in` without `else` retains Ruby's native no-match exception. An execution
that fails before choosing a branch is aborted, not counted as a selected
alternative. Selected branches and assignment paths remain observed even when
their bodies or right-hand sides subsequently raise or return.

Guarded pattern alternatives measure the selected clause, including guard
acceptance. The guard also supplies Boolean evidence when Ruby evaluates it.
A dynamic `when *candidates` is one static candidate group; the report does not
claim coverage of individual elements in that runtime collection.

Flip-flops and implicit regular-expression conditions retain Ruby's conditional
semantics and contribute one atomic predicate outcome. `defined?` measures its
result without evaluating or instrumenting the operand. Standalone predicate
calls record returned truthiness as alternative coverage; they do not claim
short-circuit conditions or coverage of library internals. Eager bitwise `&`,
`|`, and `^` are excluded because integer results do not represent Ruby
truthiness decisions: integer `0` is truthy in Ruby. These expressions add no
decisions or coverage obligations.
Dynamic dispatch records completion or exception, and preserves the original
return value. Lazy callback observations arise only when the callback runs.
Lookup coverage cannot distinguish an absent key from a stored nil; `fetch`
fallback coverage measures that separate absence-based choice.
Optional argument probes use generated local flags and preserve parameter
signatures, defaults, and existing local bindings. Code that enumerates its own
local variables can see these instrumentation locals.

Unsupported syntax stays visible and outside coverage denominators. Heredocs,
unsafe predicates, data sections, and limit overflows retain explicit exclusions.
Ruby-defined custom `!` methods keep their runtime behavior;
evidence that contradicts Boolean negation is rejected instead of proving
coverage with an invalid logical model.

New live reports use schema `1.4`; `--changed-since` reports use schema `1.5`.
Saved schema `1.0` through `1.5` reports remain readable. Comparison distinguishes decision-table coverage movement
(`rule coverage gained`, `rule coverage lost`) from analysis movement
(`rule reachability changed`), and treats a structurally changed decision as a
changed decision-table context instead of guessing which old rule a new rule
corresponds to. Expanded discovery changes coverage denominators, so compare reports
with their supported syntax scope in mind.

### Limits

`--limits` accepts a JSON object containing positive integer overrides. The
available keys are `conditions_per_decision`, `vectors_per_decision`,
`owner_associations_per_run`, `tests_per_run`, `exact_candidates`,
`exact_search_nodes`, `constraint_search_states`,
`max_conditions_for_decision_table`, and `decision_table_rules_per_decision`.

```json
{
  "vectors_per_decision": 4096,
  "exact_search_nodes": 50000
}
```

Unknown keys and non-positive values are usage errors. When a limit is
reached, the report says that evidence or analysis is incomplete; it does not
claim a complete result from truncated data.

### Runner arguments

Everything after the argument separator is passed as individual arguments to
the serial Minitest runner. This is useful for seeds and name filters:

```sh
branchproof analyze 'lib/**/*.rb' --level 1 -- --seed 9001 -n /checkout/
```

Minitest 5 and 6 both accept `-n`/`--name`. Minitest 6 also accepts
`-i`/`--include`. Minitest 6 plugins must be loaded explicitly by the application;
Branchproof preserves the framework's plugin-loading behavior. Bisect and server
modes are unsupported because they do not execute one serial local test run.

Plain Ruby compatibility is tested with Minitest 5.26.2, 5.27.0, 6.0.0, and
6.0.6. Rails integration continues to be tested with Minitest 5; Minitest 6
support does not extend the verified Rails compatibility matrix.
Minitest's own Ruby requirements also apply: Minitest 5.25.5 excludes Ruby 4,
so it cannot be selected in Branchproof's Ruby 4 bundle.

The first release supports serial Minitest and RSpec execution in plain Ruby
projects and Rails applications. Rails lazy and eager loading are supported
when the application does not enable reloading for the test run. Transactions
and in-process specs are supported within the serial process policy. Parallel
or forked runners, remote or threaded browser drivers, mutation execution,
Rails system/browser tests, custom Rails test commands, generated tests, and
reloading configurations are explicitly unsupported and produce diagnostics
rather than a passing analysis.

### Rake task

`require "branchproof/rake_task"` in a Rakefile defines a task that runs
`branchproof analyze` in a subprocess. The gem does not depend on Rake at
runtime, so the file is not loaded by `require "branchproof"`. Only options
set in the Rakefile are passed to the CLI; everything else keeps the CLI and
`.branchproof.json` defaults.

A Minitest project:

```ruby
require "branchproof/rake_task"

Branchproof::RakeTask.new(:branchproof) do |t|
  t.sources = ["lib/**/*.rb"]
  t.tests = ["test/**/*_test.rb"]
end
```

An RSpec project in a Rails application:

```ruby
Branchproof::RakeTask.new(:branchproof) do |t|
  t.sources = ["app/**/*.rb"]
  t.project = "rails"
  t.framework = "rspec"
  t.runner_args = ["--seed", "1234"]
end
```

Then run `bundle exec rake branchproof`. The task accepts `sources`, `tests`,
`project`, `framework`, `view`, `level`, `missing_only`, `minimum`, `format`,
`output`, `runner_args`, and `description`. `RakeTask#argv` returns the CLI
arguments the task will pass, which is useful for checking a Rakefile without
running the analysis.

In CI, the task exits with the CLI status, so a failed test run, a coverage
gate failure, or a usage error fails the job:

```ruby
Branchproof::RakeTask.new(:branchproof) do |t|
  t.sources = ["lib/**/*.rb"]
  t.format = "json"
  t.output = ".branchproof/coverage.json"
  t.minimum = ["mcdc=80", "decision_table=75"]
end
```

## Library entry points

```ruby
require "branchproof"

Branchproof::Limits.default
Branchproof::Records.id(name: "stable identity")
```

`require "mcdc"` and `MCDC` are compatibility aliases for the same public
namespace. The CLI is the supported way to run a complete analysis;
`Branchproof::Project` exposes project and framework selection and
child-environment policy,
and `Branchproof::RailsSupport` is the optional Rails boot boundary. The library
classes expose the source, runtime, evidence, analysis, and report contracts
for adapters and integrations. `Branchproof::CoveragePolicy#call` evaluates a
normalized `minimum` hash against a report document. `Report#coverage_policy`
returns the recomputed policy record, and `Report#coverage_policy_lines`
returns its terminal lines; both are available to integrations that need the
same gate result as the CLI.

## Development

Use an explicit Ruby executable on systems with multiple Rubies. Clearing
inherited gem paths prevents one Ruby installation from loading another's
gems:

```sh
bundle install
bundle exec rake
```

To run the real Rails integration locally, install the optional test bundle
and set its required flag:

```sh
BRANCHPROOF_RAILS_INTEGRATION=1 bundle install
BRANCHPROOF_RAILS_INTEGRATION=1 bundle exec ruby -Ilib:test test/test_rails_integration.rb
```

The flag makes a missing Rails dependency a failure in the integration job;
the core suite does not require Rails. Bootsnap is disabled for the child
Rails process so its compilation cache cannot own the load path during an
analysis.

Run the commands with CRuby 4.0 or newer and the declared Prism 1.x dependency.
The default development bundle keeps Minitest 5 for the full suite. CI runs eight
jobs on CRuby 4.0: the core suite, Minitest 5.26.2/6.0.0/6.0.6 consumer
compatibility, RSpec Core 3.13.0/3.13.6 compatibility, Rails 8.1 integration, and
rspec-rails integration. The Minitest compatibility jobs select an exact version
with `BRANCHPROOF_MINITEST_VERSION` and run adapter, CLI, lifecycle, doctor,
collation, and packaged-consumer checks. They do not require the mock library removed from
Minitest 6.
Lint runs once in the core job. Pull requests and pushes to main trigger CI.

The repeatable native-versus-instrumented adapter benchmark and its captured
Ruby 3.4.7 result are in
[`docs/benchmarks/rspec-adapter.md`](https://github.com/lucianghinda/branchproof/blob/main/docs/benchmarks/rspec-adapter.md).

## License

Branchproof is available under the [Apache License, Version 2.0](https://github.com/lucianghinda/branchproof/blob/main/LICENSE.txt).
