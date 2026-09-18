# Executable Ruby construct examples

Each `.rb` file is a complete, independent Ruby example for one catalog ID.
`IF-01` maps to `if_01.rb`, `PAT-03` to `pat_03.rb`, and so on. All 144 IDs
have a source file and named test cases in one of the four JSON manifests.

The examples demonstrate ordinary Ruby semantics. As of 0.9.0, 143 fixtures
have decision-bearing measurable coverage, with Boolean predicates and other
choices reported separately. `PRED-15` demonstrates eager integer bitwise
operators and is intentionally excluded because integer `0` is truthy, so
those results do not form a meaningful false/truthy coverage domain. Cases
exercise representative paths, not every edge case in the language catalog or
every internal branch of a called library method.

## Use the Ruby directly

From the gem root:

```ruby
load "test/fixtures/ruby_constructs/if_01.rb"

example(true)  # => "yes"
example(false) # => nil
example(nil)   # => nil
```

The whole source is also ready to pass to a parser or instrumentation test:

```ruby
source = File.read("test/fixtures/ruby_constructs/if_01.rb")
```

Most files contain just `def example(...)` and the construct being demonstrated.
Some include a small class or helper when the construct needs a receiver,
deconstruction protocol, inheritance, or another execution context. Helpers
are defined in the same file. Inputs keep loops and retries bounded.

Load only one example per fresh Ruby process: they intentionally share the
method name `example`, and some demonstrate globals or constants. `flow_12.rb`
demonstrates process termination and must run in a child process.

## Reuse the test cases

The manifests are `basic.json`, `patterns.json`, `flow.json`, and
`predicates.json`. Each entry has an `id` and a `cases` array. A case contains:

- `name`: the behavior being exercised.
- `args`: positional arguments; omitted means `[]`.
- `kwargs`: keyword arguments; omitted means `{}`. Convert these keys to symbols.
- Exactly one expectation: `result`, `error` (exception class name), or `exit`
  (process exit status).
- For `exit` cases, optional `stdout` and `stderr`; both default to empty strings.

Results and inputs use JSON values, so false and nil remain distinct. Some
results include a trace array to expose evaluated or skipped operations.
The validator compares JSON representations; it does not assert object identity
except where an example explicitly returns an identity predicate's result.

For example, to use one result case in a Minitest test in an isolated process:

```ruby
require "json"

entries = JSON.parse(File.read("test/fixtures/ruby_constructs/basic.json"))
entry = entries.find { |item| item.fetch("id") == "IF-01" }
sample = entry.fetch("cases").first

load "test/fixtures/ruby_constructs/if_01.rb"
assert_equal sample.fetch("result"), example(*sample.fetch("args"))
```

## Validate all examples

From the gem root, with either supported Ruby version selected:

```sh
ruby test/test_ruby_construct_examples.rb
```

The test checks all catalog IDs are present, runs `ruby -c` for every source,
and executes every case in a fresh subprocess with a five-second execution
timeout. Expected exceptions are assertions, not skipped tests. Compiler warnings
from intentionally unusual valid syntax (such as an implicit regexp condition)
are permitted.

The same test is included in the normal `rake test` glob. Fixtures are excluded
from RuboCop because its style transformations would erase examples such as
`unless`, `and`, explicit Boolean comparisons, or flip-flops. The test harness
itself remains linted.

When adding a catalog ID, add its file and cases and update `COUNTS` in
`test/test_ruby_construct_examples.rb`. Preserve the syntax being demonstrated;
do not simplify it into a different construct.

## Branchproof regression coverage

The native manifests remain the behavior oracle. Branchproof expectations live
separately in `expectations/source.json`, so an example can demonstrate valid
Ruby without claiming that its syntax is instrumentable.

The corpus contains 144 fixtures and 406 native cases. It is exercised through
these test layers:

| Test file | Contract |
| --- | --- |
| `test_ruby_construct_source.rb` | Reviewed inventory for every ID: decision kind, context, conditions, alternatives, and exact source locations |
| `test_ruby_construct_behavior.rb` | Every named case preserves its result, exception, trace, or process exit after rewriting |
| `test_ruby_construct_analysis.rb` | Applicable Boolean criteria, alternative coverage, partial observations, attribution, and reachability |
| `test_ruby_construct_reporting.rb` | Levels 1–3, report views, saved documents, and comparison |
| `test_ruby_construct_acceptance.rb` | Representative constructs through the real serial Minitest and CLI boundaries |

Levels 1–3 select displayed detail from the same evidence. Boolean decisions
receive decision, condition, condition/decision, masking MC/DC, and decision-table
coverage. Multiway, pattern, implicit, and exception decisions receive alternative
coverage and stay outside Boolean denominators. Optional argument binding,
recognized returned predicates, value categories, rescue paths, required patterns,
and iterator callbacks now have explicit observation contracts. Arbitrary method
entry is not counted as a decision.

The shared helper in `test/support/ruby_constructs.rb` isolates fixture execution
in child processes and reuses captured observations across assertions. The full
corpus checks Ruby semantics independently of adapters; representative Rails
loading checks remain behind `BRANCHPROOF_RAILS_INTEGRATION=1`. This suite does not
add RSpec or parallel runners.

Run the corpus suites with the project's installed bundle:

```sh
bundle exec rake test TESTOPTS='--name /TestRubyConstruct/'
```

When changing support intentionally, review the fixture and its expected
inventory together. Do not regenerate expectations merely to make a failing
test pass. A native case set need not achieve full coverage: missing obligations
and aborted executions are also regression expectations.
