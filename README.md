# Branchproof

Find missing logical cases in your Ruby tests—even when line and branch coverage are complete.

Consider an access check:

```ruby
def allowed?(paid, suspended)
  if paid && !suspended
    :allowed
  else
    :denied
  end
end
```

Test an active paid member and an unpaid visitor. Both branches run. Every executable line runs.
But neither test checks whether suspension blocks access.

Branchproof runs your existing tests and shows the missing evidence:

```text
Tests: PASSED (2 tests, 0 failed, 0 skipped)
MC/DC: 50.0% (1/2 conditions proven)
```

```text
  Condition 1: suspended
    NOT_PROVEN — Missing evidence for: suspended
      Observed decision expression: paid && !suspended
      Find two executions where:
        suspended changes between false and true
        paid remains true
        decision outcome changes between true and false
      Observed: paid = true; suspended = false; decision = true (AccessTest#test_paid_member)
      Missing counterpart: paid = true; suspended = true; decision = false (candidate; not observed)
      Boolean requirement; application-level feasibility unknown
```

These are excerpts from the real output for the example below.
The next test is concrete: **a paid, suspended member must be denied**.

Watch the code, the missing evidence, and the additional test:

![Terminal demo: two passing tests leave suspension unproven; adding a suspended paid member test reaches 100% MC/DC.](https://raw.githubusercontent.com/lucianghinda/branchproof/main/docs/demos/mcdc.gif)

[Replay or edit the VHS tapes](https://github.com/lucianghinda/branchproof/tree/main/docs/demos).

## Why line and branch coverage miss this

Line coverage tells you which lines ran. Branch coverage tells you which branches ran.
Neither establishes that each condition can independently change the result.

Our two tests already cover the `if` and `else` branches:

| Test | `paid` | `suspended` | Result |
| --- | --- | --- | --- |
| Paid member | `true` | `false` | `:allowed` |
| Unpaid visitor | `false` | `false` | `:denied` |

Remove `&& !suspended` from the implementation. **Both tests still pass.**
They cannot catch that regression, despite complete line and branch coverage for this method.

**MC/DC asks: can each condition independently change the decision?**
Modified condition/decision coverage requires a pair of executions demonstrating each condition's effect.
For suspension, keep `paid` true and change `suspended` from false to true.
The access decision must change too.

**Decision-table coverage asks: which logical rules did the tests exercise?**
For the same example, Branchproof reports:

```text
  Decision Table: 2/3 rules covered (66.67%)
    Rule  paid  suspended  Result  Status
    R1    F     -          F       COVERED
    R2    T     T          F       MISSING
    R3    T     F          T       COVERED
```

`T` means truthy, `F` means falsey, and `-` means short-circuited.
Ruby skips `suspended` when `paid` is false. Those inputs share one execution rule.
`Result` is the Boolean decision outcome, not the method's returned symbol.

<details>
<summary>Watch the decision table go from 2/3 to 3/3 covered rules</summary>

![Terminal demo: the paid and suspended rule is missing, then covered by an additional test.](https://raw.githubusercontent.com/lucianghinda/branchproof/main/docs/demos/decision-table.gif)

</details>

Here, one additional test closes both gaps. Larger decisions can distinguish the two criteria:
MC/DC proves independent effects; decision tables expose untested logical rules.
Passing one criterion does not automatically establish the other.

Coverage helps you choose tests. Assertions still need to check the intended behavior.

## Installation

Requires **CRuby 4.0 or newer**. Use your existing Minitest or RSpec bundle:

```sh
bundle add branchproof --require=false
```

Branchproof does not install a test framework. For the standalone example, start an empty directory:

```sh
bundle init
bundle add branchproof --require=false
bundle add minitest --version '~> 6.0' --require=false
mkdir -p lib test
```

## Try it

Save the `allowed?` method above in `lib/access.rb`.
Create `test/access_test.rb`:

```ruby
require "minitest/autorun"
require_relative "../lib/access"

class AccessTest < Minitest::Test
  def test_paid_member
    assert_equal :allowed, allowed?(true, false)
  end

  def test_unpaid_visitor
    assert_equal :denied, allowed?(false, false)
  end
end
```

Run the tests through Branchproof:

```sh
bundle exec branchproof analyze lib/access.rb \
  --test test/access_test.rb --level 3 --minimum mcdc=100
```

Both tests pass, but the coverage gate fails. The command exits with status 1:

```text
Coverage policy: FAILED
  mcdc: 1/2, threshold 100, FAILED
```

Add this test inside `AccessTest`:

```ruby
def test_suspended_paid_member
  assert_equal :denied, allowed?(true, true)
end
```

Run the same command again. Output excerpts:

```text
Tests: PASSED (3 tests, 0 failed, 0 skipped)
MC/DC: 100.0% (2/2 conditions proven)
```

```text
Coverage policy: PASSED
  mcdc: 2/2, threshold 100, PASSED
```

Decision-table coverage also reaches 100%: all three rules have evidence. The command exits successfully.

## Use it in your project

Start with a source file and its tests. Expand the selection when you need broader coverage.

For Minitest:

```sh
bundle exec branchproof analyze 'lib/**/*.rb' \
  --framework minitest --test 'test/**/*_test.rb' --level 3
```

For RSpec:

```sh
bundle exec branchproof analyze 'lib/**/*.rb' \
  --framework rspec --test 'spec/**/*_spec.rb' --level 3
```

For Rails, run from the application root:

```sh
bundle exec branchproof analyze 'app/**/*.rb' \
  --project rails --framework minitest --test 'test/**/*_test.rb'
```

Branchproof runs tests serially, including Rails tests.
Minitest 5 and 6 and RSpec 3.13 are supported within the
[documented compatibility limits](https://github.com/lucianghinda/branchproof/blob/main/docs/usage.md#runner-arguments).
Rails CI covers Rails 8.1 with Minitest 5 and rspec-rails 8.x.

Use Branchproof to:

- **Find the next test:** inspect missing condition values, independence pairs, and decision-table rules.
- **See contributing tests:** trace observed paths back to their test names.
- **Check a pull request:** focus coverage reports and gates on changed decisions.
- **Review results later:** save JSON, render HTML, or combine reports from serial shards.
- **Gate CI:** set explicit thresholds for the criteria you care about.

For example, require both MC/DC and decision-table coverage:

```sh
bundle exec branchproof analyze 'lib/**/*.rb' \
  --test 'test/**/*_test.rb' \
  --minimum mcdc=80 --minimum decision_table=80
```

Missing-case explanations describe required Boolean observations. They do not generate fixtures or prove input feasibility.
Unsupported syntax and incomplete observations remain visible; they are not silently credited as covered.

## Reference

- [Setup checks and configuration](https://github.com/lucianghinda/branchproof/blob/main/docs/usage.md#check-a-projects-setup)
- [Coverage criteria and decision tables](https://github.com/lucianghinda/branchproof/blob/main/docs/usage.md#coverage-ladder)
- [Missing cases and focused reports](https://github.com/lucianghinda/branchproof/blob/main/docs/usage.md#find-missing-cases)
- [Saved reports and comparison](https://github.com/lucianghinda/branchproof/blob/main/docs/usage.md#saved-reports-and-offline-comparison)
- [Report collation](https://github.com/lucianghinda/branchproof/blob/main/docs/usage.md#combine-serial-test-shards)
- [Changed-decision coverage](https://github.com/lucianghinda/branchproof/blob/main/docs/usage.md#changed-decision-coverage-and-gates)
- [GitHub Actions integration](https://github.com/lucianghinda/branchproof/blob/main/docs/usage.md#github-actions-annotations-and-job-summary)
- [Supported Ruby constructs and limits](https://github.com/lucianghinda/branchproof/blob/main/docs/usage.md#supported-decision-forms)
- [Ruby API and development](https://github.com/lucianghinda/branchproof/blob/main/docs/usage.md#library-entry-points)

## License

Branchproof is available under the [Apache License, Version 2.0](LICENSE.txt).
