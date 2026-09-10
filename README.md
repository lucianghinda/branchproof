# Branchproof

Branchproof measures modified condition/decision coverage (MC/DC) from one
serial Minitest run. It inventories supported `if`, `unless`, `elsif`,
modifier, and ordinary ternary (`?:`) decisions, records observed vectors,
and reports independence evidence, missing counterpart constraints, and
smaller supporting test sets.

The gem is named `branchproof`; its command and compatibility namespace are
`mcdc` and `MCDC`.

## Installation

```sh
gem install branchproof
```

Or add it to a bundle:

```sh
bundle add branchproof
```

Branchproof targets CRuby 3.3 and 3.4, Minitest 5.x, and Prism 1.x. The
published core runtime matrix is the CI matrix. Rails support is optional and
has been locally checked against Rails 8.1.3.1 on CRuby 3.4.5; Rails is
supplied by the application and is not a runtime dependency of this gem.
Unsupported syntax and incomplete observations remain visible in the report
instead of being counted as coverage.

## Analyze a test run

Run `mcdc analyze` with the source files or globs to inspect, followed by
options. A second `--` separates Branchproof options from arguments passed to
Minitest unchanged:

```sh
mcdc analyze 'lib/**/*.rb' --test 'test/**/*_test.rb' \
  --level 3 \
  --format terminal \
  --output tmp/branchproof.txt \
  --limits branchproof-limits.json \
  -- --seed 1234
```

For a plain Ruby application, select the project policy explicitly when
running from the application root:

```sh
bundle exec mcdc analyze 'lib/**/*.rb' --project ruby --test 'test/**/*_test.rb'
```

For a Rails application, run the same command from the application root so
the application's bundle and Rails version remain in effect:

```sh
bundle exec mcdc analyze 'app/**/*.rb' --project rails --test 'test/**/*_test.rb'
```

For a project rooted at the current directory, `--project auto` is the
default. It selects Rails only when both `config/application.rb` and
`config/environment.rb` exist; otherwise it selects a plain Ruby project.
Use `--project ruby` or `--project rails` to override detection. An explicit
Rails project without both boot files is a usage error.

Project defaults discover the sorted, de-duplicated union of
`test/**/*_test.rb` and `test/**/test_*.rb`. Helper, support, and fixture files
are excluded from that default set. `--test` remains authoritative when test
files are selected explicitly. The worker prepends the project's `lib` and
`test` directories to its child load path, so application `require` calls
resolve without changing the parent process.

Rails analysis boots `config/environment.rb` and `rails/test_help` inside the
isolated worker after Branchproof's loader and Minitest hooks are installed. The
child receives `RAILS_ENV=test`, `RACK_ENV=test`, `PARALLEL_WORKERS=1`,
`DISABLE_BOOTSNAP=1`, and `DISABLE_SPRING=1`; the invoking process environment
is unchanged. The Rails metadata in the report identifies the selected
project and Rails version.

`--output` writes the report through an atomic replacement. Without it, the
report is written to standard output. `--format` accepts `terminal` (the
default) or `json`. JSON includes source identities, criterion and schema
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

For example, running the contents of the small `decision.rb` /
`test_decision_test.rb` fixture from a project `lib/` and `test/` directory
with the terminal format produces a summary like this:

```text
Branchproof 0.3.0
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

### Find missing cases

Use `--missing-only` to focus the terminal report on conditions that still
lack independence evidence:

```sh
bundle exec mcdc analyze 'lib/**/*.rb' --missing-only
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
    NOT_PROVEN — missing observation
      Need an observation where:
        content is truthy
        Instruction.installed?(content) is falsey
        Expected decision: false [TF]
```

An existing file without the instruction block
may produce this case; the test must reach the reported line. The report
describes required truth values, not application inputs or guaranteed
reachable paths. In Ruby, only `false` and `nil` are falsey; an empty string
is truthy.

`NOT_PROVEN` means analysis ran but did not find the required pair of
observations. `NOT CALCULATED` means analysis was not available or was not
requested; check the test status and diagnostics before adding tests.
`Analysis: COMPLETE` means the analysis finished, not that every condition
was proven. Missing conditions may require new tests or changes to existing
test inputs; they do not by themselves prove a bug in the application.

The levels select how much of the one-run result is displayed:

* Level 1 reports observed vectors grouped by their raw decision outcomes.
* Level 2 includes the smallest supporting sets found for vectors and tests.
* Level 3 (the default) includes condition independence witnesses and
  counterpart constraints, as well as the Level 1 and 2 evidence.

Level 2 and Level 3 compute from the same captured run. They do not rerun the
test suite. A failed, unsupported, or incomplete run is reported with its
status and diagnostics and cannot become a successful coverage result by
changing the display level.

### Supported conditional forms

Ordinary Ruby ternaries use the same predicate instrumentation and `&&`/`||`
condition trees as supported `if` decisions. For example:

```ruby
value = ready ? false : true
```

Branchproof records `ready` as the ternary predicate. The decision outcome is
therefore the truth value of `ready`, even though the selected branch returns
`false` or `true`; branch selection, returned values, object identity, and
evaluation order are unchanged. Ternaries nested inside other predicates are
also inventoried at their own level, including all executed nested levels.
Expanding the supported syntax increases the eligible-condition denominator,
so percentages should be compared with that changed scope in mind.

The existing predicate exclusions and analysis limits still apply. Keyword
`and`/`or` expressions, contextual syntax, unsafe or ambiguous predicates,
and limit overflows remain diagnostics rather than eligible coverage.

### Limits

`--limits` accepts a JSON object containing positive integer overrides. The
available keys are `conditions_per_decision`, `vectors_per_decision`,
`owner_associations_per_run`, `tests_per_run`, `exact_candidates`,
`exact_search_nodes`, and `constraint_search_states`.

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
mcdc analyze 'lib/**/*.rb' --level 1 -- --seed 9001 -n /checkout/
```

The 0.2 release supports serial Minitest execution in plain Ruby projects and
Rails applications. Rails lazy and eager loading are supported when the
application does not enable reloading for the test run. RSpec, parallel or
forked runners, mutation execution, Rails system/browser tests, custom Rails
test commands, generated tests, and reloading configurations are outside this
release and produce diagnostics rather than a passing analysis.

## Library entry points

```ruby
require "branchproof"

Branchproof::Limits.default
Branchproof::Records.id(name: "stable identity")
```

`require "mcdc"` and `MCDC` are compatibility aliases for the same public
namespace. The CLI is the supported way to run a complete analysis;
`Branchproof::Project` exposes project selection and child-environment policy,
and `Branchproof::RailsSupport` is the optional Rails boot boundary. The library
classes expose the source, runtime, evidence, analysis, and report contracts
for adapters and integrations.

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

Run the commands with the Ruby executable you intend to validate. The checked
release environments are CRuby 3.3.6 and 3.4.5. Each runtime
must provide the declared Minitest 5.x and Prism 1.x dependencies.

## License

Branchproof is available under the [Apache License, Version 2.0](LICENSE.txt).
